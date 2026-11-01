// Throwaway verification of EditorDocumentStore. Delete after use.
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:unified_app/features/editor/controller/editor_document_store.dart';
import 'package:unified_app/features/editor/controller/editor_draft.dart';
import 'package:unified_app/features/editor/controller/editor_tab.dart';
import 'package:unified_app/features/editor/controller/file_gateway.dart';
import 'package:unified_app/features/editor/controller/workspace_paths.dart';

class FakeFile {
  FakeFile(this.text, this.version);
  String text;
  String version;
}

class FakeGateway implements FileGateway {
  final Map<String, FakeFile> files = <String, FakeFile>{};
  final List<String> writes = <String>[];
  bool available = true;
  int counter = 0;

  String _k(String ws, int root, String path) => '$ws|$root:$path';
  String _next() => 'v${++counter}';

  void put(String ws, int root, String path, String text) {
    files[_k(ws, root, path)] = FakeFile(text, _next());
  }

  @override
  bool get isAvailable => available;

  @override
  Future<FileSnapshot> readText(String ws, int root, String path) async {
    await Future<void>.delayed(Duration.zero);
    final FakeFile? f = files[_k(ws, root, path)];
    if (f == null) throw const FileMissingException();
    return FileSnapshot(text: f.text, version: f.version);
  }

  @override
  Future<PreviewSnapshot> readPreview(String ws, int root, String path) async {
    return PreviewSnapshot(
      bytes: Uint8List(0),
      kind: PreviewKind.image,
      mediaType: 'image/png',
    );
  }

  @override
  Future<String?> write(
    String ws,
    int root,
    String path,
    String content, {
    String? expectedVersion,
  }) async {
    await Future<void>.delayed(Duration.zero);
    final FakeFile? f = files[_k(ws, root, path)];
    if (f == null) throw const FileMissingException();
    if (expectedVersion != null && expectedVersion != f.version) {
      throw FileConflictException(currentVersion: f.version);
    }
    f.text = content;
    f.version = _next();
    writes.add(content);
    return f.version;
  }

  @override
  Future<String?> create(
    String ws,
    int root,
    String path,
    String content,
  ) async {
    if (files.containsKey(_k(ws, root, path))) {
      throw const FileConflictException();
    }
    put(ws, root, path, content);
    writes.add(content);
    return files[_k(ws, root, path)]!.version;
  }

  @override
  Future<String> currentVersion(String ws, int root, String path) async {
    await Future<void>.delayed(Duration.zero);
    final FakeFile? f = files[_k(ws, root, path)];
    if (f == null) throw const FileMissingException();
    return f.version;
  }
}

class FakeDrafts implements DraftStore {
  final Map<String, Map<String, EditorDraft>> data =
      <String, Map<String, EditorDraft>>{};
  bool failing = false;
  int saves = 0;

  Map<String, EditorDraft> of(String ws) =>
      data.putIfAbsent(ws, () => <String, EditorDraft>{});

  @override
  Future<Map<String, EditorDraft>> loadAll(String ws) async {
    if (failing) throw StateError('down');
    return Map<String, EditorDraft>.of(of(ws));
  }

  @override
  Future<void> save(String ws, EditorDraft draft) async {
    await Future<void>.delayed(Duration.zero);
    if (failing) throw StateError('down');
    saves++;
    of(ws)[draft.key] = draft;
  }

  @override
  Future<void> remove(String ws, String key) async {
    await Future<void>.delayed(Duration.zero);
    if (failing) throw StateError('down');
    of(ws).remove(key);
  }

  @override
  Future<void> removeAll(String ws) async {
    of(ws).clear();
  }
}

EditorDocumentStore makeStore(FakeGateway g, FakeDrafts d) =>
    EditorDocumentStore(
      gateway: g,
      drafts: d,
      draftDelay: const Duration(milliseconds: 20),
      largeDraftDelay: const Duration(milliseconds: 40),
      draftRetryDelay: const Duration(milliseconds: 60),
    );

Future<void> settle([int ms = 80]) =>
    Future<void>.delayed(Duration(milliseconds: ms));

List<WorkspaceFileReference> refs(
  List<String> paths,
) => <WorkspaceFileReference>[
  for (final String p in paths) WorkspaceFileReference(rootIndex: 0, path: p),
];

TextTab text(EditorDocumentStore s, String path) =>
    s.tabs.firstWhere((EditorTab t) => t.path == path) as TextTab;

void main() {
  test(
    'restore union of remembered tabs and drafts, with conflict detection',
    () async {
      final g = FakeGateway();
      final d = FakeDrafts();
      g.put('w', 0, 'a.md', 'alpha');
      g.put('w', 0, 'b.md', 'bravo');
      g.put('w', 0, 'c.md', 'charlie');
      g.put('w', 0, 'd.md', 'delta');
      final String vA = g.files['w|0:a.md']!.version;
      // draft against current version: restored as dirty, no conflict
      d.of('w')['0:a.md'] = EditorDraft(
        rootIndex: 0,
        path: 'a.md',
        text: 'alpha edited',
        baseVersion: vA,
        crlf: false,
        selectionBase: 3,
        selectionExtent: 5,
        savedAt: DateTime.now(),
      );
      // draft against an old version: conflict flagged
      d.of('w')['0:b.md'] = EditorDraft(
        rootIndex: 0,
        path: 'b.md',
        text: 'bravo edited',
        baseVersion: 'old',
        crlf: false,
        selectionBase: 0,
        selectionExtent: 0,
        savedAt: DateTime.now(),
      );
      // draft equal to disk: dropped
      d.of('w')['0:c.md'] = EditorDraft(
        rootIndex: 0,
        path: 'c.md',
        text: 'charlie',
        baseVersion: 'x',
        crlf: false,
        selectionBase: 0,
        selectionExtent: 0,
        savedAt: DateTime.now(),
      );
      // draft for a file not in remembered tabs: still gets a tab
      d.of('w')['0:d.md'] = EditorDraft(
        rootIndex: 0,
        path: 'd.md',
        text: 'delta edited',
        baseVersion: g.files['w|0:d.md']!.version,
        crlf: false,
        selectionBase: 0,
        selectionExtent: 0,
        savedAt: DateTime.now(),
      );
      // draft for a deleted file
      d.of('w')['0:gone.md'] = EditorDraft(
        rootIndex: 0,
        path: 'gone.md',
        text: 'precious',
        baseVersion: 'z',
        crlf: false,
        selectionBase: 0,
        selectionExtent: 0,
        savedAt: DateTime.now(),
      );

      final s = makeStore(g, d);
      String? reportedActive;
      List<WorkspaceFileReference> reported = <WorkspaceFileReference>[];
      s.onTabsChanged =
          (String ws, List<WorkspaceFileReference> files, String? active) {
            reported = files;
            reportedActive = active;
          };
      await s.switchWorkspace(
        'w',
        remembered: refs(<String>['a.md', 'b.md', 'c.md', 'stale.md']),
        activeKey: '0:b.md',
      );

      expect(s.tabs.map((EditorTab t) => t.path).toList(), <String>[
        'a.md',
        'b.md',
        'c.md',
        'd.md',
        'gone.md',
      ]);
      final TextTab a = text(s, 'a.md');
      expect(a.text, 'alpha edited');
      expect(a.isDirty, isTrue);
      expect(a.external, ExternalChange.none);
      expect(a.selection, const TextSelection(baseOffset: 3, extentOffset: 5));
      final TextTab b = text(s, 'b.md');
      expect(b.text, 'bravo edited');
      expect(b.external, ExternalChange.changed);
      expect(b.externalVersion, g.files['w|0:b.md']!.version);
      final TextTab c = text(s, 'c.md');
      expect(c.isDirty, isFalse);
      await settle();
      expect(
        d.of('w').containsKey('0:c.md'),
        isFalse,
        reason: 'redundant draft removed',
      );
      final TextTab gone = text(s, 'gone.md');
      expect(gone.external, ExternalChange.deleted);
      expect(gone.text, 'precious');
      expect(s.activeKey, '0:b.md');
      expect(reportedActive, '0:b.md');
      expect(
        reported.map((WorkspaceFileReference r) => r.path).toList(),
        <String>['a.md', 'b.md', 'c.md', 'd.md', 'gone.md'],
      );

      // saving the deleted file recreates it
      expect(await s.save(gone), isTrue);
      expect(g.files['w|0:gone.md']!.text, 'precious');
      expect(gone.external, ExternalChange.none);
      await settle();
      expect(d.of('w').containsKey('0:gone.md'), isFalse);

      // conflict: plain save refused, disk untouched
      expect(await s.save(b), isFalse);
      expect(g.files['w|0:b.md']!.text, 'bravo');
      expect(b.external, ExternalChange.changed);
      // overwrite resolves
      expect(await s.overwriteDisk(b), isTrue);
      expect(g.files['w|0:b.md']!.text, 'bravo edited');
      expect(b.external, ExternalChange.none);
      expect(b.isDirty, isFalse);
      await settle();
      expect(d.of('w').containsKey('0:b.md'), isFalse);
      s.dispose();
    },
  );

  test('typing is persisted as a draft and survives a restart', () async {
    final g = FakeGateway();
    final d = FakeDrafts();
    g.put('w', 0, 'n.md', 'one\ntwo');
    var s = makeStore(g, d);
    await s.switchWorkspace(
      'w',
      remembered: refs(<String>['n.md']),
      activeKey: '0:n.md',
    );
    final TextTab t = text(s, 'n.md');
    s.edited(t, 'one\ntwo\nthree', const TextSelection.collapsed(offset: 13));
    expect(t.isDirty, isTrue);
    expect(d.of('w'), isEmpty, reason: 'debounced');
    await settle();
    expect(d.of('w')['0:n.md']!.text, 'one\ntwo\nthree');
    expect(d.of('w')['0:n.md']!.baseVersion, g.files['w|0:n.md']!.version);
    s.dispose();

    // restart
    s = makeStore(g, d);
    await s.switchWorkspace(
      'w',
      remembered: refs(<String>['n.md']),
      activeKey: '0:n.md',
    );
    final TextTab r = text(s, 'n.md');
    expect(r.text, 'one\ntwo\nthree');
    expect(r.isDirty, isTrue);
    expect(r.recoveredFromDraft, isTrue);
    expect(r.external, ExternalChange.none);
    expect(r.selection.baseOffset, 13);
    // undo back to the saved text clears the draft
    s.edited(r, 'one\ntwo', const TextSelection.collapsed(offset: 7));
    expect(r.isDirty, isFalse);
    await settle();
    expect(d.of('w'), isEmpty);
    s.dispose();
  });

  test('flushDrafts reports failure and recovers', () async {
    final g = FakeGateway();
    final d = FakeDrafts();
    g.put('w', 0, 'n.txt', 'x');
    final s = makeStore(g, d);
    await s.switchWorkspace('w', remembered: refs(<String>['n.txt']));
    final TextTab t = text(s, 'n.txt');
    d.failing = true;
    s.edited(t, 'xy', const TextSelection.collapsed(offset: 2));
    expect(await s.flushDrafts(), isFalse);
    d.failing = false;
    // automatic retry
    await settle(200);
    expect(d.of('w')['0:n.txt']!.text, 'xy');
    s.edited(t, 'xyz', const TextSelection.collapsed(offset: 3));
    expect(await s.flushDrafts(), isTrue);
    expect(d.of('w')['0:n.txt']!.text, 'xyz');
    s.dispose();
  });

  test(
    'saving keeps CRLF and byte exactness; mixed endings stay raw',
    () async {
      final g = FakeGateway();
      final d = FakeDrafts();
      g.put('w', 0, 'crlf.txt', 'a  \r\nb\t\r\n\r\n');
      g.put('w', 0, 'mixed.txt', 'a\r\nb\nc\r');
      g.put('w', 0, 'lf.txt', 'x\n\n\n');
      final s = makeStore(g, d);
      await s.switchWorkspace(
        'w',
        remembered: refs(<String>['crlf.txt', 'mixed.txt', 'lf.txt']),
      );
      final TextTab c = text(s, 'crlf.txt');
      expect(c.text, 'a  \nb\t\n\n');
      expect(c.crlf, isTrue);
      expect(c.isDirty, isFalse);
      s.edited(c, 'a  \nb\t\n\nnew', const TextSelection.collapsed(offset: 0));
      expect(await s.save(c), isTrue);
      expect(g.files['w|0:crlf.txt']!.text, 'a  \r\nb\t\r\n\r\nnew');
      // a pasted CRLF does not double
      s.edited(
        c,
        'a  \nb\t\r\n\nnew',
        const TextSelection.collapsed(offset: 0),
      );
      expect(await s.save(c), isTrue);
      expect(g.files['w|0:crlf.txt']!.text, 'a  \r\nb\t\r\n\r\nnew');

      final TextTab m = text(s, 'mixed.txt');
      expect(m.crlf, isFalse);
      expect(m.text, 'a\r\nb\nc\r');
      s.edited(m, 'a\r\nb\nc\rd', const TextSelection.collapsed(offset: 0));
      expect(await s.save(m), isTrue);
      expect(g.files['w|0:mixed.txt']!.text, 'a\r\nb\nc\rd');

      final TextTab l = text(s, 'lf.txt');
      s.edited(l, 'x\n\n\n\n', const TextSelection.collapsed(offset: 0));
      expect(await s.save(l), isTrue);
      expect(
        g.files['w|0:lf.txt']!.text,
        'x\n\n\n\n',
        reason: 'blank lines are never trimmed',
      );
      s.dispose();
    },
  );

  test('external changes: clean tabs reload, dirty tabs are flagged, deletes are noticed', () async {
    final g = FakeGateway();
    final d = FakeDrafts();
    g.put('w', 0, 'clean.md', 'one');
    g.put('w', 0, 'dirty.md', 'one');
    g.put('w', 0, 'del.md', 'one');
    final s = makeStore(g, d);
    await s.switchWorkspace(
      'w',
      remembered: refs(<String>['clean.md', 'dirty.md', 'del.md']),
    );
    final TextTab clean = text(s, 'clean.md');
    final TextTab dirty = text(s, 'dirty.md');
    final TextTab del = text(s, 'del.md');
    s.edited(dirty, 'mine', const TextSelection.collapsed(offset: 4));

    g.files['w|0:clean.md']!
      ..text = 'two'
      ..version = 'ext1';
    g.files['w|0:dirty.md']!
      ..text = 'theirs'
      ..version = 'ext2';
    g.files.remove('w|0:del.md');

    final int revision = clean.revision;
    await s.checkExternalChanges();
    expect(clean.text, 'two');
    expect(clean.isDirty, isFalse);
    expect(clean.revision, revision + 1);
    expect(dirty.text, 'mine');
    expect(dirty.external, ExternalChange.changed);
    expect(dirty.externalVersion, 'ext2');
    expect(del.external, ExternalChange.deleted);

    // dirty can reload from disk
    expect(await s.reloadFromDisk(dirty), isTrue);
    expect(dirty.text, 'theirs');
    expect(dirty.external, ExternalChange.none);
    await settle();
    expect(d.of('w'), isEmpty);
    s.dispose();
  });

  test(
    'moves re-key tabs and drafts; workspace switching keeps unsaved tabs',
    () async {
      final g = FakeGateway();
      final d = FakeDrafts();
      g.put('w', 0, 'dir/a.md', 'a');
      g.put('w', 0, 'dir/b.md', 'b');
      g.put('v', 0, 'other.md', 'o');
      final s = makeStore(g, d);
      await s.switchWorkspace(
        'w',
        remembered: refs(<String>['dir/a.md', 'dir/b.md']),
        activeKey: '0:dir/a.md',
      );
      final TextTab a = text(s, 'dir/a.md');
      s.edited(a, 'a!', const TextSelection.collapsed(offset: 2));
      await settle();
      expect(d.of('w').keys, <String>['0:dir/a.md']);

      s.applyMove(
        const WorkspaceFileMove(
          sourceRootIndex: 0,
          sourcePath: 'dir',
          destinationRootIndex: 0,
          destinationPath: 'moved/dir',
          isDirectory: true,
        ),
      );
      expect(s.tabs.map((EditorTab t) => t.path).toList(), <String>[
        'moved/dir/a.md',
        'moved/dir/b.md',
      ]);
      expect(s.activeKey, '0:moved/dir/a.md');
      await settle();
      expect(d.of('w').keys, <String>['0:moved/dir/a.md']);

      // switch away and back: the dirty tab is still there
      await s.switchWorkspace('v', remembered: refs(<String>['other.md']));
      expect(s.tabs.map((EditorTab t) => t.path).toList(), <String>[
        'other.md',
      ]);
      await s.switchWorkspace('w');
      expect(s.tabs.length, 2);
      expect(identical(text(s, 'moved/dir/a.md'), a), isTrue);
      expect(a.text, 'a!');
      s.dispose();
    },
  );

  test('a delete closes the tabs at or under the path and drops drafts', () async {
    final g = FakeGateway();
    final d = FakeDrafts();
    g.put('w', 0, 'dir/a.md', 'a');
    g.put('w', 0, 'dir/sub/b.md', 'b');
    g.put('w', 0, 'dirty.md', 'x');
    g.put('w', 0, 'keep.md', 'k');
    final s = makeStore(g, d);
    await s.switchWorkspace(
      'w',
      remembered: refs(<String>['dir/a.md', 'dir/sub/b.md', 'dirty.md', 'keep.md']),
      activeKey: '0:dir/a.md',
    );
    final TextTab b = text(s, 'dir/sub/b.md');
    s.edited(b, 'b!', const TextSelection.collapsed(offset: 2));
    await settle();
    expect(d.of('w').keys, <String>['0:dir/sub/b.md']);

    // A file path does not match a sibling that only shares its prefix.
    expect(s.tabsAtOrUnder(0, 'dir', isDirectory: false), isEmpty);
    expect(
      s.tabsAtOrUnder(0, 'dir', isDirectory: true).map((EditorTab t) => t.path),
      <String>['dir/a.md', 'dir/sub/b.md'],
    );
    expect(s.tabsAtOrUnder(1, 'dir', isDirectory: true), isEmpty);

    s.closeAtOrUnder(0, 'dir', isDirectory: true);
    expect(s.tabs.map((EditorTab t) => t.path).toList(), <String>[
      'dirty.md',
      'keep.md',
    ]);
    expect(s.activeKey, isNot('0:dir/a.md'));
    await settle();
    expect(d.of('w'), isEmpty);

    s.closeAtOrUnder(0, 'dirty.md', isDirectory: false);
    expect(s.tabs.map((EditorTab t) => t.path).toList(), <String>['keep.md']);
    s.dispose();
  });

  test('isWorkspacePathAtOrUnder matches the target and, for folders, its contents', () {
    bool under(String path, String target, {bool dir = true, int root = 0}) =>
        isWorkspacePathAtOrUnder(
          rootIndex: root,
          path: path,
          targetRootIndex: 0,
          targetPath: target,
          targetIsDirectory: dir,
        );
    expect(under('dir', 'dir'), isTrue);
    expect(under('dir/a.md', 'dir'), isTrue);
    expect(under(r'dir\sub\b.md', 'dir'), isTrue);
    expect(under('dir/a.md', 'dir', dir: false), isFalse);
    expect(under('directory/a.md', 'dir'), isFalse);
    expect(under('dir/a.md', 'dir', root: 1), isFalse);
  });

  test('open during restore does not duplicate; latest open wins focus; offline restore is deferred', () async {
    final g = FakeGateway();
    final d = FakeDrafts();
    g.put('w', 0, 'a.md', 'a');
    g.put('w', 0, 'b.md', 'b');
    g.put('w', 0, 'c.md', 'c');
    final s = makeStore(g, d);
    g.available = false;
    int reports = 0;
    s.onTabsChanged = (String ws, List<WorkspaceFileReference> f, String? k) =>
        reports++;
    await s.switchWorkspace(
      'w',
      remembered: refs(<String>['a.md']),
      activeKey: '0:a.md',
    );
    expect(s.tabs, isEmpty);
    expect(
      reports,
      0,
      reason: 'nothing is reported, so remembered tabs are not wiped',
    );
    g.available = true;
    final Future<EditorTab?> first = s.open(0, 'b.md');
    final Future<EditorTab?> second = s.open(0, 'c.md');
    await Future.wait(<Future<EditorTab?>>[first, second]);
    expect(s.tabs.map((EditorTab t) => t.path).toList(), <String>[
      'a.md',
      'b.md',
      'c.md',
    ]);
    expect(s.activeKey, '0:c.md');
    await s.open(0, 'a.md');
    expect(s.tabs.length, 3);
    expect(s.activeKey, '0:a.md');
    s.close(text(s, 'c.md'));
    expect(s.tabs.length, 2);
    s.dispose();
  });

  test(
    'a save in flight keeps typed text dirty and writes the new draft',
    () async {
      final g = FakeGateway();
      final d = FakeDrafts();
      g.put('w', 0, 'n.md', 'one');
      final s = makeStore(g, d);
      await s.switchWorkspace('w', remembered: refs(<String>['n.md']));
      final TextTab t = text(s, 'n.md');
      s.edited(t, 'two', const TextSelection.collapsed(offset: 3));
      final Future<bool> saving = s.save(t);
      s.edited(t, 'two!', const TextSelection.collapsed(offset: 4));
      expect(await saving, isTrue);
      expect(g.files['w|0:n.md']!.text, 'two');
      expect(t.savedText, 'two');
      expect(t.isDirty, isTrue);
      await settle();
      expect(d.of('w')['0:n.md']!.text, 'two!');
      expect(d.of('w')['0:n.md']!.baseVersion, g.files['w|0:n.md']!.version);
      s.dispose();
    },
  );
}
