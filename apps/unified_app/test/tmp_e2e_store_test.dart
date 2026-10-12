// Throwaway end-to-end check of the editor store against a real engine.
// Requires the engine from the verification run on port 55693. Delete after use.
import 'dart:convert';
import 'dart:io';

import 'package:core_business_logic/core_business_logic.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:unified_app/features/dashboard/controller/dashboard_controller.dart';
import 'package:unified_app/features/editor/controller/editor_document_store.dart';
import 'package:unified_app/features/editor/controller/editor_tab.dart';

const String endpoint = 'http://127.0.0.1:55693';
const String token = 'subconscious-dev-token';
final String root = '${Platform.environment['TEMP']}\\subc-e2e';
final String wsDir = '$root\\ws';

EngineRepository newRepository() => EngineRepository(
  rest: RestEngineClient(baseUri: Uri.parse('$endpoint/api/v1/'), token: token),
  socket: WebSocketEngineClient(
    endpoint: Uri.parse('ws://127.0.0.1:55693/api/v1/events?token=$token'),
  ),
);

Future<DashboardController> startController(String workspaceUuid) async {
  final DashboardController controller = DashboardController(
    ({Uri? explicitEndpoint, String? explicitToken}) async => newRepository(),
    initialWorkspaceUuid: workspaceUuid,
  );
  await controller.load();
  await waitFor(() => controller.documents.workspaceUuid == workspaceUuid && !controller.documents.isRestoring);
  return controller;
}

Future<void> waitFor(bool Function() condition, {int ms = 8000}) async {
  final Stopwatch watch = Stopwatch()..start();
  while (!condition()) {
    if (watch.elapsedMilliseconds > ms) throw TimeoutException2('condition not met in $ms ms');
    await Future<void>.delayed(const Duration(milliseconds: 25));
  }
}

class TimeoutException2 implements Exception {
  TimeoutException2(this.message);
  final String message;
  @override
  String toString() => message;
}

TextTab tab(DashboardController c, String path) =>
    c.documents.tabs.firstWhere((EditorTab t) => t.path == path) as TextTab;

Future<List<EngineSetting>> drafts(String ws) =>
    newRepository().rest.getSettings(tag: 'editor-draft:$ws', client: 'flutter');

List<int> bytesOf(String name) => File('$wsDir\\$name').readAsBytesSync();

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late String ws;

  setUpAll(() {
    HttpOverrides.global = null;
    ws = File('$root\\workspace.txt').readAsStringSync().trim();
  });

  test('open, edit, restart with and without a saved tab list, save, byte exactness', () async {
    final DashboardController first = await startController(ws);
    final bool opened = await first.openWorkspaceFile(0, 'notes.md');
    // ignore: avoid_print
    print('opened=$opened active=${first.activeWorkspace?.uuid} error=${first.filesError} connected=${first.isConnected} err=${first.error}');
    expect(opened, isTrue);
    TextTab notes = tab(first, 'notes.md');
    final String original = notes.text;
    expect(original, startsWith('# Notes'));
    expect(first.activeFileReference?.path, 'notes.md');

    first.documents.edited(notes, '$original\nadded line', TextSelection.collapsed(offset: original.length + 11));
    expect(notes.isDirty, isTrue);
    await Future<void>.delayed(const Duration(milliseconds: 1200));
    List<EngineSetting> rows = await drafts(ws);
    expect(rows.length, 1);
    expect(rows.single.key, '0:notes.md');
    final Map<String, dynamic> stored = jsonDecode(rows.single.value) as Map<String, dynamic>;
    expect(stored['text'], '$original\nadded line');

    // Crash: the saved tab list never reached the engine, only the draft did.
    // A new run must still bring the tab back, from the draft alone.
    await newRepository().rest.deleteSettings(key: DashboardController.appStateKey);
    final DashboardController crashed = await startController(ws);
    await waitFor(() => crashed.documents.tabs.isNotEmpty);
    notes = tab(crashed, 'notes.md');
    expect(notes.text, '$original\nadded line');
    expect(notes.isDirty, isTrue);
    expect(notes.recoveredFromDraft, isTrue);
    expect(notes.external, ExternalChange.none);
    expect(File('$wsDir\\notes.md').readAsStringSync(), original, reason: 'disk untouched by drafts');

    // Normal exit: app state is flushed too.
    await crashed.flushAppState();
    expect(await crashed.documents.flushDrafts(), isTrue);
    final DashboardController again = await startController(ws);
    await waitFor(() => again.documents.tabs.isNotEmpty);
    expect(again.documents.tabs.map((EditorTab t) => t.path), <String>['notes.md']);
    expect(again.documents.activeKey, '0:notes.md');
    notes = tab(again, 'notes.md');
    expect(notes.text, '$original\nadded line');

    // Save: confirmed write, exact bytes, draft removed.
    expect(await again.documents.save(notes), isTrue);
    expect(File('$wsDir\\notes.md').readAsStringSync(), '$original\nadded line');
    expect(notes.isDirty, isFalse);
    await Future<void>.delayed(const Duration(milliseconds: 600));
    expect(await drafts(ws), isEmpty);

    first.dispose();
    crashed.dispose();
    again.dispose();
  });

  test('CRLF and trailing whitespace survive an edit byte for byte; BOM kept', () async {
    final DashboardController c = await startController(ws);
    expect(await c.openWorkspaceFile(0, 'readme.txt'), isTrue);
    final TextTab t = tab(c, 'readme.txt');
    expect(t.crlf, isTrue);
    expect(t.text, 'line one  \n\ttabbed line\n\n\nlast line\n\n');
    final List<int> before = bytesOf('readme.txt');
    c.documents.edited(t, '${t.text}appended', const TextSelection.collapsed(offset: 0));
    expect(await c.documents.save(t), isTrue);
    final List<int> after = bytesOf('readme.txt');
    expect(utf8.decode(after), 'line one  \r\n\ttabbed line\r\n\r\n\r\nlast line\r\n\r\nappended');
    expect(after.sublist(0, before.length), before, reason: 'untouched bytes identical');

    expect(await c.openWorkspaceFile(0, 'bom.txt'), isTrue);
    final TextTab b = tab(c, 'bom.txt');
    expect(b.text, 'bom file\n');
    c.documents.edited(b, 'bom file\nmore\n', const TextSelection.collapsed(offset: 0));
    expect(await c.documents.save(b), isTrue);
    expect(bytesOf('bom.txt').sublist(0, 3), <int>[0xEF, 0xBB, 0xBF]);
    expect(utf8.decode(bytesOf('bom.txt').sublist(3)), 'bom file\nmore\n');

    expect(await c.openWorkspaceFile(0, 'script.py'), isTrue);
    final TextTab p = tab(c, 'script.py');
    expect(p.text, contains('\treturn'));
    c.dispose();
  });

  test('external changes: clean tab reloads, dirty tab conflicts, overwrite resolves', () async {
    final DashboardController c = await startController(ws);
    File('$wsDir\\ext.md').writeAsStringSync('one\n');
    expect(await c.openWorkspaceFile(0, 'ext.md'), isTrue);
    final TextTab t = tab(c, 'ext.md');

    File('$wsDir\\ext.md').writeAsStringSync('two\n');
    await c.refreshOpenFile();
    expect(t.text, 'two\n');
    expect(t.isDirty, isFalse);

    c.documents.edited(t, 'mine\n', const TextSelection.collapsed(offset: 0));
    File('$wsDir\\ext.md').writeAsStringSync('theirs\n');
    await c.refreshOpenFile();
    expect(t.external, ExternalChange.changed);
    expect(t.text, 'mine\n');
    expect(await c.documents.save(t), isFalse, reason: 'engine refuses the stale write');
    expect(File('$wsDir\\ext.md').readAsStringSync(), 'theirs\n');
    expect(t.external, ExternalChange.changed);
    expect(await c.documents.overwriteDisk(t), isTrue);
    expect(File('$wsDir\\ext.md').readAsStringSync(), 'mine\n');
    expect(t.external, ExternalChange.none);

    File('$wsDir\\ext.md').deleteSync();
    await c.refreshOpenFile();
    expect(t.external, ExternalChange.deleted);
    c.documents.edited(t, 'recreated\n', const TextSelection.collapsed(offset: 0));
    expect(await c.documents.save(t), isTrue);
    expect(File('$wsDir\\ext.md').readAsStringSync(), 'recreated\n');
    File('$wsDir\\ext.md').deleteSync();
    c.dispose();
  });

  test('large files open and save', () async {
    final DashboardController c = await startController(ws);
    final Stopwatch watch = Stopwatch()..start();
    expect(await c.openWorkspaceFile(0, 'big.txt'), isTrue);
    // ignore: avoid_print
    print('open big.txt (858 KB): ${watch.elapsedMilliseconds} ms');
    final TextTab big = tab(c, 'big.txt');
    expect(big.text.length, 858894);
    watch.reset();
    c.documents.edited(big, '${big.text}tail', const TextSelection.collapsed(offset: 0));
    expect(await c.documents.save(big), isTrue);
    // ignore: avoid_print
    print('save big.txt: ${watch.elapsedMilliseconds} ms');
    // restore the original so reruns start clean
    c.documents.edited(big, big.text.substring(0, big.text.length - 4), const TextSelection.collapsed(offset: 0));
    expect(await c.documents.save(big), isTrue);

    expect(await c.openWorkspaceFile(0, 'huge.txt'), isFalse);
    expect(c.filesError.toString(), contains('1 MB'));
    expect(c.documents.tabs.any((EditorTab t) => t.path == 'huge.txt'), isFalse);
    c.dispose();
  });
}
