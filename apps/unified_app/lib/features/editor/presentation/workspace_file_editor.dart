import 'dart:async';

import 'package:core_business_logic/core_business_logic.dart';
import 'package:fluentui_system_icons/fluentui_system_icons.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_ui_kit/shared_ui_kit.dart';

import '../../context/presentation/workspace_document_preview.dart';
import '../../context/presentation/workspace_image_preview.dart';
import '../../dashboard/controller/dashboard_controller.dart';
import '../controller/editor_document_store.dart';
import '../controller/editor_tab.dart';
import '../controller/file_gateway.dart';
import 'code_editor_surface.dart';
import 'file_tab_button.dart';
import 'markdown/markdown_ribbon.dart';
import 'source_editor.dart';

/// The main panel's file editor: a tab bar over the active file.
///
/// The tabs, their unsaved text and every rule about saving live in the
/// controller's [EditorDocumentStore]. This widget only shows them, so leaving
/// the Files view or closing the app never takes an edit with it.
final class WorkspaceFileEditor extends StatefulWidget {
  /// The editor for the dashboard's open files.
  WorkspaceFileEditor({required DashboardController controller, Key? key})
    : this.forStore(store: controller.documents, refresh: controller, key: key);

  /// An editor over any document store. [refresh] is rebuilt on as well, for
  /// state the store does not own, such as the engine connection.
  const WorkspaceFileEditor.forStore({
    required this.store,
    this.refresh,
    super.key,
  });

  final EditorDocumentStore store;
  final Listenable? refresh;

  @override
  State<WorkspaceFileEditor> createState() => _WorkspaceFileEditorState();
}

enum _CloseChoice { save, discard, cancel }

final class _WorkspaceFileEditorState extends State<WorkspaceFileEditor> {
  final Map<String, MarkdownViewMode> _viewModes = <String, MarkdownViewMode>{};
  bool _focusEditorNext = false;

  EditorDocumentStore get _store => widget.store;

  Future<void> _save(TextTab tab) async {
    await _store.save(tab);
  }

  void _selectTab(EditorTab tab) {
    if (tab.key == _store.activeKey) return;
    _focusEditorNext = true;
    _store.activate(tab.key);
  }

  Future<void> _closeTab(EditorTab tab) async {
    if (tab is TextTab && tab.isDirty) {
      final _CloseChoice? choice = await showAppDialog<_CloseChoice>(
        context: context,
        builder: (BuildContext context) => AppDialog(
          title: 'Save changes to ${tab.name}?',
          content: const Text(
            'If you do not save, the changes you made to this file are lost.',
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.pop(context, _CloseChoice.cancel),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, _CloseChoice.discard),
              child: const Text("Don't save"),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, _CloseChoice.save),
              child: const Text('Save'),
            ),
          ],
        ),
      );
      if (choice == null || choice == _CloseChoice.cancel || !mounted) return;
      if (choice == _CloseChoice.save) {
        final bool saved = await _store.save(tab);
        // A failed save keeps the tab open so the problem is visible.
        if (!saved || !mounted) return;
      }
    }
    _viewModes.remove(tab.key);
    _store.close(tab);
  }

  @override
  Widget build(BuildContext context) {
    final EditorDocumentStore store = _store;
    final Listenable? refresh = widget.refresh;
    return ListenableBuilder(
      listenable: Listenable.merge(<Listenable>[store, ?refresh]),
      builder: (BuildContext context, Widget? child) {
        final ColorScheme colors = Theme.of(context).colorScheme;
        final EditorTab? active = store.active;
        if (active == null) {
          if (store.isRestoring || store.isOpening) {
            return ColoredBox(
              color: colors.surface,
              child: const Center(
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            );
          }
          return ColoredBox(
            color: colors.surface,
            child: Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Text(
                      'Main panel',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      'Select a file from the context panel to open it here.',
                      textAlign: TextAlign.center,
                    ),
                  ],
                ),
              ),
            ),
          );
        }
        final bool autofocus = _focusEditorNext;
        _focusEditorNext = false;
        final SingleActivator save = SingleActivator(
          LogicalKeyboardKey.keyS,
          control: !usesCommandKey,
          meta: usesCommandKey,
        );
        return AppFormTheme(
          child: CallbackShortcuts(
            bindings: <ShortcutActivator, VoidCallback>{
              save: () {
                final EditorTab? tab = store.active;
                if (tab is TextTab && tab.isDirty) unawaited(_save(tab));
              },
            },
            child: ColoredBox(
              color: colors.surface,
              child: Column(
                children: <Widget>[
                  _tabBar(context, store, active),
                  if (active is TextTab) ..._banners(context, active),
                  Expanded(child: _body(context, active, autofocus)),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _tabBar(
    BuildContext context,
    EditorDocumentStore store,
    EditorTab active,
  ) {
    final bool connected = store.gateway.isAvailable;
    final TextTab? text = active is TextTab ? active : null;
    final bool canSave =
        text != null && text.isDirty && !text.isSaving && connected;
    return SizedBox(
      height: 48,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Row(
          children: <Widget>[
            Expanded(
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: <Widget>[
                    for (final EditorTab tab in store.tabs)
                      Padding(
                        padding: const EdgeInsets.only(right: 6),
                        child: FileTabButton(
                          label: tab.name,
                          selected: tab.key == store.activeKey,
                          dirty: tab is TextTab && tab.isDirty,
                          warning: tab is TextTab && tab.hasExternalChange,
                          onTap: () => _selectTab(tab),
                          onClose: () => unawaited(_closeTab(tab)),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            const SizedBox(width: 8),
            if (text != null)
              Tooltip(
                message: connected ? 'Save (${shortcutPrefix}S)' : 'Not connected to the engine. Your changes are kept as a draft.',
                child: FilledButton.icon(
                  onPressed: canSave ? () => unawaited(_save(text)) : null,
                  icon: text.isSaving
                      ? const SizedBox.square(
                          dimension: 14,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(FluentIcons.save_20_regular, size: 16),
                  label: const Text('Save'),
                ),
              ),
          ],
        ),
      ),
    );
  }

  List<Widget> _banners(BuildContext context, TextTab tab) {
    final List<Widget> banners = <Widget>[];
    switch (tab.external) {
      case ExternalChange.changed:
        banners.add(
          _EditorBanner(
            tone: _BannerTone.warning,
            message: tab.recoveredFromDraft
                ? 'Your unsaved changes were recovered, but the file on disk '
                      'has changed since. Choose which version to keep.'
                : 'This file changed on disk while you were editing it. '
                      'Choose which version to keep.',
            actions: <Widget>[
              TextButton(
                onPressed: () => unawaited(_store.reloadFromDisk(tab)),
                child: const Text('Load from disk'),
              ),
              TextButton(
                onPressed: tab.isSaving
                    ? null
                    : () => unawaited(_store.overwriteDisk(tab)),
                child: const Text('Overwrite with mine'),
              ),
            ],
          ),
        );
      case ExternalChange.deleted:
        banners.add(
          _EditorBanner(
            tone: _BannerTone.warning,
            message:
                'This file was deleted or moved on disk. Your text is still '
                'here. Save to create the file again.',
            actions: <Widget>[
              TextButton(
                onPressed: tab.isSaving ? null : () => unawaited(_save(tab)),
                child: const Text('Save to recreate'),
              ),
            ],
          ),
        );
      case ExternalChange.none:
        break;
    }
    final Object? saveError = tab.saveError;
    if (saveError != null) {
      banners.add(
        _EditorBanner(
          tone: _BannerTone.error,
          message: "Couldn't save: ${describeEditorError(saveError)}",
          actions: <Widget>[
            TextButton(
              onPressed: tab.isSaving ? null : () => unawaited(_save(tab)),
              child: const Text('Try again'),
            ),
          ],
        ),
      );
    }
    if (tab.recoveredFromDraft && tab.external == ExternalChange.none) {
      banners.add(
        _EditorBanner(
          tone: _BannerTone.info,
          message: 'Restored your unsaved changes from last time.',
          actions: <Widget>[
            TextButton(
              onPressed: () => _store.acknowledgeRecovery(tab),
              child: const Text('Dismiss'),
            ),
          ],
        ),
      );
    }
    final bool largeForKind = switch (tab.kind) {
      EditorKind.markdown => tab.isLarge,
      EditorKind.code =>
        tab.text.length > CodeEditorSurface.highlightLimitChars,
      EditorKind.plainText => false,
    };
    if (largeForKind) {
      banners.add(
        const _EditorBanner(
          tone: _BannerTone.info,
          message:
              'Large file: styling is turned off to keep typing responsive.',
        ),
      );
    }
    return banners;
  }

  Widget _body(BuildContext context, EditorTab tab, bool autofocus) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    if (tab is PreviewTab) {
      if (tab.isDocument) {
        return WorkspaceDocumentPreview(
          key: ValueKey<String>(tab.key),
          bytes: tab.bytes,
          kind: tab.kind.name,
        );
      }
      return Padding(
        padding: const EdgeInsets.all(12),
        child: ClipRRect(
          borderRadius: AppRadii.standard,
          child: ColoredBox(
            color: colors.surfaceContainerLowest,
            child: WorkspaceImagePreview(bytes: tab.bytes, isSvg: tab.isSvg),
          ),
        ),
      );
    }
    final TextTab text = tab as TextTab;
    // A new key whenever the text is replaced from outside the editor makes
    // the text field start over from the new content.
    final Key key = ValueKey<String>('${text.key}#${text.revision}');
    switch (text.kind) {
      case EditorKind.markdown:
        return SourceEditor(
          key: key,
          store: _store,
          tab: text,
          markdown: true,
          viewMode: _viewModes[text.key] ?? MarkdownViewMode.edit,
          onViewModeChanged: (MarkdownViewMode mode) =>
              setState(() => _viewModes[text.key] = mode),
          autofocus: autofocus,
        );
      case EditorKind.plainText:
        return SourceEditor(
          key: key,
          store: _store,
          tab: text,
          markdown: false,
          autofocus: autofocus,
        );
      case EditorKind.code:
        if (text.text.length > CodeEditorSurface.highlightLimitChars) {
          return SourceEditor(
            key: key,
            store: _store,
            tab: text,
            markdown: false,
            autofocus: autofocus,
          );
        }
        return CodeEditorSurface(
          key: key,
          store: _store,
          tab: text,
          autofocus: autofocus,
        );
    }
  }
}

/// A plain-language description of a file operation failure.
String describeEditorError(Object error) {
  if (error is EngineApiException) {
    return error.engineMessage ??
        'The engine answered with ${error.statusCode}.';
  }
  if (error is TimeoutException) return 'The engine took too long to answer.';
  if (error is FileUnavailableException) return error.message;
  if (error is StateError) return error.message;
  return '$error';
}

enum _BannerTone { info, warning, error }

final class _EditorBanner extends StatelessWidget {
  const _EditorBanner({
    required this.tone,
    required this.message,
    this.actions = const <Widget>[],
  });

  final _BannerTone tone;
  final String message;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 6),
      child: AppBanner(
        tone: switch (tone) {
          _BannerTone.info => AppBannerTone.info,
          _BannerTone.warning => AppBannerTone.warning,
          _BannerTone.error => AppBannerTone.error,
        },
        message: message,
        actions: actions,
      ),
    );
  }
}
