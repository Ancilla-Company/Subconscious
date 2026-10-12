import 'dart:async';
import 'dart:collection';

import 'package:flutter/widgets.dart';

import 'editor_draft.dart';
import 'editor_tab.dart';
import 'file_gateway.dart';
import 'line_endings.dart';
import 'workspace_paths.dart';

/// Called whenever the set of open tabs, or the active one, changes.
typedef TabsChangedCallback =
    void Function(
      String workspaceUuid,
      List<WorkspaceFileReference> files,
      String? activeKey,
    );

/// The files a workspace has open. Kept for as long as the app runs, so
/// switching away from a workspace never throws away its unsaved edits.
final class _Session {
  _Session(this.uuid);

  final String uuid;
  final List<EditorTab> tabs = <EditorTab>[];
  String? activeKey;
  bool restored = false;
  bool restoring = false;
  Future<void>? restoration;
  List<WorkspaceFileReference> remembered = const <WorkspaceFileReference>[];
  String? rememberedActiveKey;
}

/// Bookkeeping for writing one tab's draft to the draft store.
final class _DraftTracker {
  Timer? timer;

  /// Draft writes for one tab run strictly one after another, so an older
  /// write can never land after a newer one.
  Future<void> chain = Future<void>.value();
  int edits = 0;
  int persisted = 0;
  bool failed = false;
  bool closed = false;
  bool checking = false;

  /// The key under which a draft for this tab is currently stored.
  String? storedKey;
}

/// Owns every open editor tab, the unsaved text in them, and the rules that
/// keep that text from being lost or from overwriting someone else's changes.
///
/// The widget layer only reads this state and reports edits; saving, drafts,
/// restoring after a restart and external-change detection all live here, so
/// they keep working when the editor is not on screen.
final class EditorDocumentStore extends ChangeNotifier {
  EditorDocumentStore({
    required this.gateway,
    required this.drafts,
    this.draftDelay = const Duration(milliseconds: 600),
    this.largeDraftDelay = const Duration(seconds: 2),
    this.draftRetryDelay = const Duration(seconds: 5),
  });

  final FileGateway gateway;
  final DraftStore drafts;

  /// How long typing must pause before a draft is written.
  final Duration draftDelay;

  /// The same, for files too large to rewrite on every pause.
  final Duration largeDraftDelay;

  /// How long to wait before retrying a draft write that failed.
  final Duration draftRetryDelay;

  /// Reports the open files of the active workspace so the app can remember
  /// them across restarts.
  TabsChangedCallback? onTabsChanged;

  /// Reports a change of the active tab.
  void Function(EditorTab? active)? onActiveChanged;

  final Map<String, _Session> _sessions = <String, _Session>{};
  final Expando<_DraftTracker> _trackers = Expando<_DraftTracker>(
    'editor drafts',
  );
  String? _currentUuid;
  int _opening = 0;
  int _openSequence = 0;
  bool _disposed = false;
  _LifecycleObserver? _lifecycle;

  _Session? get _session {
    final String? uuid = _currentUuid;
    return uuid == null ? null : _sessions[uuid];
  }

  String? get workspaceUuid => _currentUuid;

  List<EditorTab> get tabs =>
      UnmodifiableListView<EditorTab>(_session?.tabs ?? const <EditorTab>[]);

  String? get activeKey => _session?.activeKey;

  EditorTab? get active {
    final _Session? session = _session;
    if (session == null) return null;
    for (final EditorTab tab in session.tabs) {
      if (tab.key == session.activeKey) return tab;
    }
    return null;
  }

  WorkspaceFileReference? get activeReference => active?.reference;

  /// True while the saved tabs of the active workspace are being read.
  bool get isRestoring => _session?.restoring ?? false;

  /// True while a file the user asked for is being read.
  bool get isOpening => _opening > 0;

  /// Every tab, in every workspace, whose text differs from the file.
  Iterable<TextTab> get dirtyTabs sync* {
    for (final _Session session in _sessions.values) {
      for (final EditorTab tab in session.tabs) {
        if (tab is TextTab && tab.isDirty) yield tab;
      }
    }
  }

  bool get hasUnsavedChanges => dirtyTabs.isNotEmpty;

  // ---------------------------------------------------------------------------
  // Workspaces and restoring
  // ---------------------------------------------------------------------------

  /// Makes [uuid] the workspace whose tabs are shown.
  ///
  /// The first time a workspace is shown its remembered tabs are read and any
  /// stored drafts are put back, so every draft has a tab even if the saved tab
  /// list did not make it to disk before the app closed. Later switches reuse
  /// the tabs already open.
  Future<void> switchWorkspace(
    String? uuid, {
    List<WorkspaceFileReference> remembered = const <WorkspaceFileReference>[],
    String? activeKey,
  }) {
    if (_disposed) return Future<void>.value();
    final String? previous = _currentUuid;
    _currentUuid = uuid;
    if (previous != null && previous != uuid) unawaited(flushDrafts());
    if (uuid == null) {
      _notify();
      onActiveChanged?.call(null);
      return Future<void>.value();
    }
    final _Session? existing = _sessions[uuid];
    if (existing != null) {
      _notify();
      onActiveChanged?.call(active);
      if (!existing.restored && !existing.restoring) {
        return _beginRestore(existing);
      }
      unawaited(checkExternalChanges());
      return existing.restoration ?? Future<void>.value();
    }
    final _Session session = _Session(uuid)
      ..remembered = remembered
      ..rememberedActiveKey = activeKey;
    _sessions[uuid] = session;
    return _beginRestore(session);
  }

  /// Retries a restore that was skipped because the engine was unreachable.
  Future<void> retryRestore() async {
    final _Session? session = _session;
    if (session == null || session.restored || session.restoring) return;
    await _beginRestore(session);
  }

  Future<void> _beginRestore(_Session session) {
    if (!gateway.isAvailable) {
      // Nothing is reported and nothing is forgotten: the remembered tabs and
      // the stored drafts stay as they are until the engine is back.
      _notify();
      return Future<void>.value();
    }
    session.restoring = true;
    _notify();
    final Future<void> restoration = _restore(session).whenComplete(() {
      session.restoring = false;
      session.restoration = null;
      _notify();
    });
    session.restoration = restoration;
    return restoration;
  }

  Future<void> _restore(_Session session) async {
    Map<String, EditorDraft> stored = const <String, EditorDraft>{};
    try {
      stored = await drafts.loadAll(session.uuid);
    } on Object {
      // Unreadable drafts must not stop the saved tabs from coming back.
    }
    final List<WorkspaceFileReference> references = <WorkspaceFileReference>[
      ...session.remembered,
    ];
    final Set<String> known = <String>{
      for (final WorkspaceFileReference reference in references)
        reference.key,
    };
    for (final EditorDraft draft in stored.values) {
      if (known.add(draft.key)) {
        references.add(
          WorkspaceFileReference(rootIndex: draft.rootIndex, path: draft.path),
        );
      }
    }
    final List<EditorTab?> loaded = await Future.wait(<Future<EditorTab?>>[
      for (final WorkspaceFileReference reference in references)
        _restoreOne(session, reference, stored[reference.key]),
    ]);
    if (_disposed || !identical(_sessions[session.uuid], session)) {
      for (final EditorTab? tab in loaded) {
        if (tab != null) _release(tab);
      }
      return;
    }
    final Set<String> present = <String>{
      for (final EditorTab tab in session.tabs) tab.key,
    };
    final List<EditorTab> restored = <EditorTab>[
      for (final EditorTab? tab in loaded)
        if (tab != null && present.add(tab.key)) tab,
    ];
    session.tabs.insertAll(0, restored);
    if (session.activeKey == null) {
      String? wanted;
      for (final EditorTab tab in session.tabs) {
        if (tab.key == session.rememberedActiveKey) wanted = tab.key;
      }
      session.activeKey =
          wanted ?? (session.tabs.isEmpty ? null : session.tabs.last.key);
    }
    session.restored = true;
    if (session.uuid == _currentUuid) {
      _reportTabs(session);
      onActiveChanged?.call(active);
    }
  }

  Future<EditorTab?> _restoreOne(
    _Session session,
    WorkspaceFileReference reference,
    EditorDraft? draft,
  ) async {
    final String uuid = session.uuid;
    if (PreviewKind.forPath(reference.path) != null) {
      try {
        return await _loadPreview(uuid, reference.rootIndex, reference.path);
      } on Object {
        return null;
      }
    }
    try {
      final FileSnapshot snapshot = await gateway.readText(
        uuid,
        reference.rootIndex,
        reference.path,
      );
      return _tabFromDisk(uuid, reference, snapshot, draft);
    } on FileMissingException {
      return draft == null ? null : _tabForMissingFile(uuid, reference, draft);
    } on Object {
      return draft == null
          ? null
          : _tabForUnverifiedFile(uuid, reference, draft);
    }
  }

  TextTab _tabFromDisk(
    String uuid,
    WorkspaceFileReference reference,
    FileSnapshot snapshot,
    EditorDraft? draft,
  ) {
    final LineEndings disk = LineEndings.fromDisk(snapshot.text);
    if (draft == null || draft.text == disk.text) {
      final TextTab tab = TextTab(
        workspaceUuid: uuid,
        rootIndex: reference.rootIndex,
        path: reference.path,
        text: disk.text,
        savedText: disk.text,
        diskVersion: snapshot.version,
        crlf: disk.crlf,
      );
      // A draft equal to the file protects nothing, so it is dropped.
      if (draft != null) {
        _tracker(tab).storedKey = draft.key;
        unawaited(_persist(tab));
      }
      return tab;
    }
    final TextTab tab = TextTab(
      workspaceUuid: uuid,
      rootIndex: reference.rootIndex,
      path: reference.path,
      text: draft.text,
      savedText: disk.text,
      diskVersion: draft.baseVersion,
      crlf: disk.crlf,
      selection: TextSelection(
        baseOffset: draft.selectionBase,
        extentOffset: draft.selectionExtent,
      ),
    )..recoveredFromDraft = true;
    if (draft.baseVersion != snapshot.version) {
      tab
        ..external = ExternalChange.changed
        ..externalVersion = snapshot.version;
    }
    _tracker(tab).storedKey = draft.key;
    return tab;
  }

  TextTab? _tabForMissingFile(
    String uuid,
    WorkspaceFileReference reference,
    EditorDraft draft,
  ) {
    if (draft.text.isEmpty) {
      unawaited(_discardDraft(uuid, draft.key));
      return null;
    }
    final TextTab tab = TextTab(
      workspaceUuid: uuid,
      rootIndex: reference.rootIndex,
      path: reference.path,
      text: draft.text,
      savedText: '',
      diskVersion: null,
      crlf: draft.crlf,
      selection: TextSelection(
        baseOffset: draft.selectionBase,
        extentOffset: draft.selectionExtent,
      ),
    )..recoveredFromDraft = true;
    tab.external = ExternalChange.deleted;
    _tracker(tab).storedKey = draft.key;
    return tab;
  }

  TextTab _tabForUnverifiedFile(
    String uuid,
    WorkspaceFileReference reference,
    EditorDraft draft,
  ) {
    final TextTab tab = TextTab(
      workspaceUuid: uuid,
      rootIndex: reference.rootIndex,
      path: reference.path,
      text: draft.text,
      savedText: '',
      diskVersion: draft.baseVersion,
      crlf: draft.crlf,
      selection: TextSelection(
        baseOffset: draft.selectionBase,
        extentOffset: draft.selectionExtent,
      ),
    )..recoveredFromDraft = true;
    // The file could not be read, so what is on disk is unknown. The tab is
    // flagged instead of being trusted.
    tab.external = ExternalChange.changed;
    _tracker(tab).storedKey = draft.key;
    return tab;
  }

  Future<PreviewTab> _loadPreview(
    String uuid,
    int rootIndex,
    String path,
  ) async {
    final PreviewSnapshot preview = await gateway.readPreview(
      uuid,
      rootIndex,
      path,
    );
    return PreviewTab(
      workspaceUuid: uuid,
      rootIndex: rootIndex,
      path: path,
      bytes: preview.bytes,
      kind: preview.kind,
      mediaType: preview.mediaType,
    );
  }

  // ---------------------------------------------------------------------------
  // Opening, activating and closing
  // ---------------------------------------------------------------------------

  /// Opens a file in a tab, or switches to its tab when it is already open.
  ///
  /// Returns null when the workspace changed before the file arrived.
  Future<EditorTab?> open(
    int rootIndex,
    String path, {
    bool activate = true,
  }) async {
    final String? uuid = _currentUuid;
    final _Session? session = _session;
    if (uuid == null || session == null) {
      throw StateError('Select a workspace before opening a file.');
    }
    // Tabs being restored must exist first, or a file would open twice. A
    // restore that was skipped while the engine was away starts now.
    if (!session.restored && !session.restoring && gateway.isAvailable) {
      await _beginRestore(session);
    }
    final Future<void>? restoration = session.restoration;
    if (restoration != null) await restoration;
    final String key = workspaceFileKey(rootIndex, path);
    final EditorTab? existing = _find(session, key);
    if (existing != null) {
      if (activate) this.activate(key);
      return existing;
    }
    final int request = ++_openSequence;
    _opening++;
    _notify();
    try {
      final EditorTab tab;
      if (PreviewKind.forPath(path) != null) {
        tab = await _loadPreview(uuid, rootIndex, path);
      } else {
        final FileSnapshot snapshot = await gateway.readText(
          uuid,
          rootIndex,
          path,
        );
        final LineEndings disk = LineEndings.fromDisk(snapshot.text);
        tab = TextTab(
          workspaceUuid: uuid,
          rootIndex: rootIndex,
          path: path,
          text: disk.text,
          savedText: disk.text,
          diskVersion: snapshot.version,
          crlf: disk.crlf,
        );
      }
      if (_disposed || !identical(_sessions[uuid], session)) return null;
      final EditorTab? raced = _find(session, key);
      if (raced != null) {
        if (activate) this.activate(key);
        return raced;
      }
      session.tabs.add(tab);
      // Only the most recent request takes the focus, so a slow read cannot
      // pull the user back to a file they have already moved on from.
      if (activate && request == _openSequence) session.activeKey = key;
      if (uuid == _currentUuid) {
        _reportTabs(session);
        if (session.activeKey == key) onActiveChanged?.call(tab);
      }
      return tab;
    } finally {
      _opening--;
      _notify();
    }
  }

  /// Makes the tab with [key] the active one.
  void activate(String key) {
    final _Session? session = _session;
    if (session == null || session.activeKey == key) return;
    if (_find(session, key) == null) return;
    // Text typed in the tab being left is written out right away.
    unawaited(flushDrafts());
    session.activeKey = key;
    _reportTabs(session);
    _notify();
    onActiveChanged?.call(active);
    unawaited(checkExternalChanges(onlyKey: key));
  }

  /// Closes [tab] and forgets its draft. Callers confirm with the user first
  /// when the tab has unsaved changes.
  void close(EditorTab tab) {
    final _Session? session = _sessions[tab.workspaceUuid];
    if (session == null) return;
    final int index = session.tabs.indexOf(tab);
    if (index < 0) return;
    final bool wasActive = tab.key == session.activeKey;
    session.tabs.removeAt(index);
    _release(tab, discardDraft: true);
    if (wasActive) {
      session.activeKey = session.tabs.isEmpty
          ? null
          : session.tabs[index.clamp(0, session.tabs.length - 1)].key;
    }
    if (session.uuid == _currentUuid) {
      _reportTabs(session);
      if (wasActive) onActiveChanged?.call(active);
    }
    _notify();
  }

  /// Rebases open tabs after a file or folder was moved in the file tree.
  void applyMove(WorkspaceFileMove move) {
    final _Session? session = _session;
    if (session == null) return;
    final String? activeKey = session.activeKey;
    bool activeMoved = false;
    bool changed = false;
    for (final EditorTab tab in session.tabs) {
      final String? rebased = rebaseWorkspacePath(
        rootIndex: tab.rootIndex,
        path: tab.path,
        move: move,
      );
      if (rebased == null) continue;
      final bool wasActive = tab.key == activeKey;
      tab
        ..rootIndex = move.destinationRootIndex
        ..path = rebased;
      if (wasActive) {
        activeMoved = true;
        session.activeKey = tab.key;
      }
      changed = true;
      // The draft is stored under the file's path, so it moves with the file.
      if (tab is TextTab && (tab.isDirty || _tracker(tab).storedKey != null)) {
        unawaited(_persist(tab));
      }
    }
    if (!changed) return;
    _reportTabs(session);
    _notify();
    if (activeMoved) onActiveChanged?.call(active);
  }

  /// Drops everything held for a workspace that no longer exists.
  Future<void> forgetWorkspace(String uuid) async {
    final _Session? session = _sessions.remove(uuid);
    if (session != null) {
      for (final EditorTab tab in session.tabs) {
        _release(tab);
      }
    }
    if (_currentUuid == uuid) {
      _currentUuid = null;
      onActiveChanged?.call(null);
    }
    _notify();
    try {
      await drafts.removeAll(uuid);
    } on Object {
      // Orphaned drafts are harmless; they are never restored.
    }
  }

  // ---------------------------------------------------------------------------
  // Editing and drafts
  // ---------------------------------------------------------------------------

  /// Records the text and selection the editor is showing for [tab].
  void edited(TextTab tab, String text, TextSelection selection) {
    // A closed tab has had its draft discarded; a late edit must not bring it
    // back.
    if (_tracker(tab).closed) return;
    tab.selection = selection;
    if (tab.text == text) return;
    final bool wasDirty = tab.isDirty;
    tab.text = text;
    if (tab.isDirty != wasDirty) _notify();
    _scheduleDraft(tab);
  }

  void _scheduleDraft(TextTab tab) {
    final _DraftTracker tracker = _tracker(tab);
    tracker.edits++;
    tracker.timer?.cancel();
    final Duration delay = tab.isLarge ? largeDraftDelay : draftDelay;
    tracker.timer = Timer(delay, () {
      tracker.timer = null;
      unawaited(_persist(tab));
    });
  }

  EditorDraft _draftOf(TextTab tab) {
    final int length = tab.text.length;
    return EditorDraft(
      rootIndex: tab.rootIndex,
      path: tab.path,
      text: tab.text,
      baseVersion: tab.diskVersion,
      crlf: tab.crlf,
      selectionBase: tab.selection.baseOffset.clamp(0, length),
      selectionExtent: tab.selection.extentOffset.clamp(0, length),
      savedAt: DateTime.now().toUtc(),
    );
  }

  /// Brings the stored draft for [tab] in line with its text: writes it while
  /// the tab is dirty and removes it once the tab is clean.
  Future<bool> _persist(TextTab tab) {
    final _DraftTracker tracker = _tracker(tab);
    tracker.timer?.cancel();
    tracker.timer = null;
    final Future<void> step = tracker.chain.then((_) async {
      final int target = tracker.edits;
      try {
        final String? storedKey = tracker.storedKey;
        if (storedKey != null && storedKey != tab.key) {
          await drafts.remove(tab.workspaceUuid, storedKey);
          tracker.storedKey = null;
        }
        if (tab.isDirty) {
          await drafts.save(tab.workspaceUuid, _draftOf(tab));
          tracker.storedKey = tab.key;
        } else if (tracker.storedKey != null) {
          await drafts.remove(tab.workspaceUuid, tracker.storedKey!);
          tracker.storedKey = null;
        }
        tracker.persisted = target;
        tracker.failed = false;
      } on Object {
        tracker.failed = true;
        if (!_disposed && !tracker.closed) {
          tracker.timer ??= Timer(draftRetryDelay, () {
            tracker.timer = null;
            unawaited(_persist(tab));
          });
        }
      }
    });
    tracker.chain = step;
    return step.then((_) => !tracker.failed);
  }

  Future<void> _discardDraft(String uuid, String key) async {
    try {
      await drafts.remove(uuid, key);
    } on Object {
      // A leftover draft is restored as a normal tab next time.
    }
  }

  /// Writes out every draft that has not reached the draft store yet.
  ///
  /// Returns true only when all of them are safely stored. Callers that are
  /// about to end the process use the result to warn about unsaved text.
  Future<bool> flushDrafts() async {
    final List<Future<bool>> pending = <Future<bool>>[];
    for (final _Session session in _sessions.values) {
      for (final EditorTab tab in session.tabs) {
        if (tab is! TextTab) continue;
        final _DraftTracker tracker = _tracker(tab);
        final bool needsWrite =
            tracker.timer != null ||
            tracker.edits != tracker.persisted ||
            tracker.failed;
        pending.add(
          needsWrite
              ? _persist(tab)
              : tracker.chain.then((_) => !tracker.failed),
        );
      }
    }
    final List<bool> results = await Future.wait(pending);
    return results.every((bool stored) => stored);
  }

  // ---------------------------------------------------------------------------
  // Saving and external changes
  // ---------------------------------------------------------------------------

  /// Writes [tab] to disk. Returns true only when the engine confirmed it.
  Future<bool> save(TextTab tab) async {
    if (tab.isSaving) return false;
    if (!gateway.isAvailable) {
      tab.saveError = const FileUnavailableException();
      _notify();
      return false;
    }
    tab
      ..isSaving = true
      ..saveError = null;
    _notify();
    final String sent = tab.text;
    final String payload = LineEndings.toDisk(sent, crlf: tab.crlf);
    try {
      final String? version;
      if (tab.external == ExternalChange.deleted) {
        version = await gateway.create(
          tab.workspaceUuid,
          tab.rootIndex,
          tab.path,
          payload,
        );
      } else {
        version = await gateway.write(
          tab.workspaceUuid,
          tab.rootIndex,
          tab.path,
          payload,
          expectedVersion: tab.diskVersion,
        );
      }
      tab
        ..savedText = sent
        ..diskVersion = version
        ..external = ExternalChange.none
        ..externalVersion = null
        ..recoveredFromDraft = false;
      // What is left of the text, if anything, is the part typed during the
      // save. Either way the stored draft is brought up to date.
      _tracker(tab).edits++;
      unawaited(_persist(tab));
      return true;
    } on FileConflictException catch (conflict) {
      tab
        ..external = ExternalChange.changed
        ..externalVersion = conflict.currentVersion;
      return false;
    } on FileMissingException {
      if (tab.external == ExternalChange.deleted) {
        tab.saveError = StateError(
          'The folder this file was in no longer exists.',
        );
      } else {
        tab.external = ExternalChange.deleted;
      }
      return false;
    } on Object catch (error) {
      tab.saveError = error;
      return false;
    } finally {
      tab.isSaving = false;
      _notify();
    }
  }

  /// Hides the notice that [tab]'s text came back from a draft.
  void acknowledgeRecovery(TextTab tab) {
    if (!tab.recoveredFromDraft) return;
    tab.recoveredFromDraft = false;
    _notify();
  }

  /// Saves every unsaved tab of the active workspace.
  Future<bool> saveAll() async {
    final _Session? session = _session;
    if (session == null) return true;
    final List<bool> results = await Future.wait(<Future<bool>>[
      for (final EditorTab tab in List<EditorTab>.of(session.tabs))
        if (tab is TextTab && tab.isDirty) save(tab),
    ]);
    return results.every((bool saved) => saved);
  }

  /// Resolves a conflict in favour of the text in the editor: the file on disk
  /// is overwritten with it.
  Future<bool> overwriteDisk(TextTab tab) async {
    if (tab.external == ExternalChange.changed) {
      try {
        tab.diskVersion =
            tab.externalVersion ??
            await gateway.currentVersion(
              tab.workspaceUuid,
              tab.rootIndex,
              tab.path,
            );
        tab.externalVersion = null;
      } on FileMissingException {
        tab.external = ExternalChange.deleted;
      } on Object catch (error) {
        tab.saveError = error;
        _notify();
        return false;
      }
    }
    return save(tab);
  }

  /// Resolves a conflict in favour of the file: the editor text is discarded
  /// and replaced with what is on disk.
  Future<bool> reloadFromDisk(TextTab tab) async {
    try {
      final FileSnapshot snapshot = await gateway.readText(
        tab.workspaceUuid,
        tab.rootIndex,
        tab.path,
      );
      _replaceFromDisk(tab, snapshot);
      return true;
    } on FileMissingException {
      tab.external = ExternalChange.deleted;
      _notify();
      return false;
    } on Object catch (error) {
      tab.saveError = error;
      _notify();
      return false;
    }
  }

  void _replaceFromDisk(TextTab tab, FileSnapshot snapshot) {
    final LineEndings disk = LineEndings.fromDisk(snapshot.text);
    tab
      ..text = disk.text
      ..savedText = disk.text
      ..crlf = disk.crlf
      ..diskVersion = snapshot.version
      ..external = ExternalChange.none
      ..externalVersion = null
      ..saveError = null
      ..recoveredFromDraft = false
      ..selection = TextSelection(
        baseOffset: tab.selection.baseOffset.clamp(0, disk.text.length),
        extentOffset: tab.selection.extentOffset.clamp(0, disk.text.length),
      )
      ..revision += 1;
    _tracker(tab).edits++;
    unawaited(_persist(tab));
    _notify();
  }

  /// Compares each open file with the one on disk.
  ///
  /// A tab without edits quietly takes the new content. A tab with edits is
  /// flagged instead, so the user decides which version to keep.
  Future<void> checkExternalChanges({String? onlyKey}) async {
    final _Session? session = _session;
    if (session == null || !gateway.isAvailable) return;
    await Future.wait(<Future<void>>[
      for (final EditorTab tab in List<EditorTab>.of(session.tabs))
        if (tab is TextTab && (onlyKey == null || tab.key == onlyKey))
          _checkOne(session, tab),
    ]);
  }

  Future<void> _checkOne(_Session session, TextTab tab) async {
    final _DraftTracker tracker = _tracker(tab);
    if (tracker.checking || tab.isSaving) return;
    tracker.checking = true;
    try {
      final String version;
      try {
        version = await gateway.currentVersion(
          tab.workspaceUuid,
          tab.rootIndex,
          tab.path,
        );
      } on FileMissingException {
        if (_isLive(session, tab)) _setExternal(tab, ExternalChange.deleted);
        return;
      }
      if (!_isLive(session, tab) || tab.isSaving) return;
      if (version == tab.diskVersion) {
        _setExternal(tab, ExternalChange.none);
        return;
      }
      if (tab.isDirty) {
        _setExternal(tab, ExternalChange.changed, version: version);
        return;
      }
      final FileSnapshot snapshot = await gateway.readText(
        tab.workspaceUuid,
        tab.rootIndex,
        tab.path,
      );
      // Typing during the read wins over the reload.
      if (!_isLive(session, tab) || tab.isDirty || tab.isSaving) return;
      _replaceFromDisk(tab, snapshot);
    } on Object {
      // A failed check leaves the tab as it was; the next one tries again.
    } finally {
      tracker.checking = false;
    }
  }

  void _setExternal(TextTab tab, ExternalChange change, {String? version}) {
    if (tab.external == change && tab.externalVersion == version) return;
    tab
      ..external = change
      ..externalVersion = version;
    _notify();
  }

  // ---------------------------------------------------------------------------
  // App lifecycle
  // ---------------------------------------------------------------------------

  /// Writes drafts when the app loses focus and re-checks files when it comes
  /// back. Safe to call more than once.
  void observeAppLifecycle() {
    if (_lifecycle != null || _disposed) return;
    final _LifecycleObserver observer = _LifecycleObserver(this);
    _lifecycle = observer;
    WidgetsBinding.instance.addObserver(observer);
  }

  // ---------------------------------------------------------------------------
  // Internals
  // ---------------------------------------------------------------------------

  _DraftTracker _tracker(TextTab tab) =>
      _trackers[tab] ??= _DraftTracker();

  EditorTab? _find(_Session session, String key) {
    for (final EditorTab tab in session.tabs) {
      if (tab.key == key) return tab;
    }
    return null;
  }

  bool _isLive(_Session session, EditorTab tab) =>
      !_disposed &&
      identical(_sessions[session.uuid], session) &&
      session.tabs.contains(tab);

  void _reportTabs(_Session session) {
    if (session.uuid != _currentUuid || !session.restored) return;
    onTabsChanged?.call(session.uuid, <WorkspaceFileReference>[
      for (final EditorTab tab in session.tabs) tab.reference,
    ], session.activeKey);
  }

  void _release(EditorTab tab, {bool discardDraft = false}) {
    if (tab is! TextTab) return;
    final _DraftTracker tracker = _tracker(tab);
    tracker.closed = true;
    tracker.timer?.cancel();
    tracker.timer = null;
    if (discardDraft) {
      final String? storedKey = tracker.storedKey;
      tracker.chain = tracker.chain.then((_) async {
        if (storedKey == null) return;
        await _discardDraft(tab.workspaceUuid, storedKey);
        tracker.storedKey = null;
      });
    }
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    final _LifecycleObserver? observer = _lifecycle;
    if (observer != null) WidgetsBinding.instance.removeObserver(observer);
    _lifecycle = null;
    for (final _Session session in _sessions.values) {
      for (final EditorTab tab in session.tabs) {
        if (tab is TextTab) _tracker(tab).timer?.cancel();
      }
    }
    super.dispose();
  }
}

final class _LifecycleObserver with WidgetsBindingObserver {
  _LifecycleObserver(this._store);

  final EditorDocumentStore _store;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(_store.checkExternalChanges());
    } else {
      unawaited(_store.flushDrafts());
    }
  }
}
