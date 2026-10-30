import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_ui_kit/shared_ui_kit.dart';
import 'package:unified_app/features/context/presentation/context_panel.dart';
import 'package:unified_app/features/dashboard/controller/dashboard_controller.dart';

/// Regression: these dialogs used to dispose their text controller as soon as
/// the dialog's future completed, while the dialog was still animating out.
/// The field then rebuilt with a disposed controller ("A TextEditingController
/// was used after being disposed").
Future<void> _open<T>(
  WidgetTester tester,
  Widget dialog,
  void Function(T?) onResult,
) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (BuildContext context) => TextButton(
            onPressed: () async =>
                onResult(await showAppDialog<T>(context: context, builder: (_) => dialog)),
            child: const Text('open'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('rename: submitting closes the dialog without a disposed-controller error', (
    tester,
  ) async {
    String? result = 'unset';
    await _open<String>(
      tester,
      const RenameDialog(name: 'notes.md', isDirectory: false),
      (String? value) => result = value,
    );
    await tester.enterText(find.byType(EditableText), 'ideas.md');
    await tester.tap(find.text('Rename'));
    // Step through the exit animation frame by frame; the old code threw here.
    for (int i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 30));
    }
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(result, 'ideas.md');
  });

  testWidgets('rename: cancel and a rejected name behave', (tester) async {
    String? result = 'unset';
    await _open<String>(
      tester,
      const RenameDialog(name: 'notes.md', isDirectory: false),
      (String? value) => result = value,
    );
    await tester.enterText(find.byType(EditableText), 'a/b');
    await tester.tap(find.text('Rename'));
    await tester.pump();
    expect(find.textContaining('Enter a name without slashes'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    for (int i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 30));
    }
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(result, isNull);
  });

  testWidgets('new file: creates a path in the chosen root and closes cleanly', (
    tester,
  ) async {
    ({int rootIndex, String path})? result;
    await _open<({int rootIndex, String path})>(
      tester,
      const CreatePathDialog(
        roots: <WorkspaceDirectoryRoot>[
          WorkspaceDirectoryRoot(index: 0, path: '/work/alpha'),
          WorkspaceDirectoryRoot(index: 1, path: '/work/beta'),
        ],
        initialLocation: (rootIndex: 1, path: 'docs'),
        isFile: true,
      ),
      (({int rootIndex, String path})? value) => result = value,
    );
    // The initial location picks its root and prefills the folder.
    expect(find.text('beta'), findsWidgets);
    expect(
      tester.widget<EditableText>(find.byType(EditableText)).controller.text,
      'docs/',
    );
    await tester.enterText(find.byType(EditableText), 'docs/todo.txt');
    await tester.tap(find.text('Create file'));
    for (int i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 30));
    }
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(result, (rootIndex: 1, path: 'docs/todo.txt'));
  });

  testWidgets('new folder: an absolute or dotted path is refused', (tester) async {
    await _open<({int rootIndex, String path})>(
      tester,
      const CreatePathDialog(
        roots: <WorkspaceDirectoryRoot>[
          WorkspaceDirectoryRoot(index: 0, path: '/work/alpha'),
        ],
        initialLocation: null,
        isFile: false,
      ),
      (_) {},
    );
    await tester.enterText(find.byType(EditableText), '../escape');
    await tester.tap(find.text('Create'));
    await tester.pump();
    expect(find.textContaining('without . or .. segments'), findsOneWidget);
  });
}
