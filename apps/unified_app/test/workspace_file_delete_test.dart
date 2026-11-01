import 'dart:async';
import 'dart:convert';

import 'package:core_business_logic/core_business_logic.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:unified_app/features/dashboard/controller/dashboard_controller.dart';

final class _FakeSocket implements EngineSocket {
  bool connected = false;

  @override
  bool get isConnected => connected;

  @override
  Stream<WireFrame> get frames => const Stream<WireFrame>.empty();

  @override
  Future<void> connect() async => connected = true;

  @override
  void registerUiTools() {}

  @override
  Future<void> close() async => connected = false;

  @override
  Future<void> dispose() async => connected = false;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

http.Response _json(Object body, [int status = 200]) => http.Response(
  jsonEncode(body),
  status,
  headers: <String, String>{'content-type': 'application/json'},
);

Map<String, dynamic> _entry(String path, {bool dir = false}) =>
    <String, dynamic>{
      'name': path.split('/').last,
      'relativePath': path,
      'isDirectory': dir,
    };

/// An engine with one workspace whose root holds `dir/b.md` and `a.md`.
final class _FilesEngine {
  final List<http.Request> deletes = <http.Request>[];
  final List<http.Request> copies = <http.Request>[];
  int deleteStatus = 204;
  int copyStatus = 200;
  bool dirDeleted = false;
  bool copied = false;

  EngineRepository repository() => EngineRepository(
    rest: RestEngineClient(
      baseUri: Uri.parse('http://127.0.0.1:50507/api/v1/'),
      token: 't',
      client: MockClient((http.Request request) async {
        final String path = request.url.path;
        if (path.endsWith('/health')) {
          return _json(<String, dynamic>{'status': 'ok'});
        }
        if (path.endsWith('/api/v1/workspaces')) {
          return _json(<Object>[
            <String, dynamic>{
              'uuid': 'w',
              'name': 'W',
              'directories': jsonEncode(<String>['C:/root']),
            },
          ]);
        }
        if (path.endsWith('/workspaces/w/files/copy')) {
          copies.add(request);
          if (copyStatus != 200) {
            return _json(<String, dynamic>{'error': 'A file or directory already exists at the destination.'}, copyStatus);
          }
          copied = true;
          return _json(_entry('copies/a.md'));
        }
        if (path.endsWith('/workspaces/w/files')) {
          if (request.method == 'DELETE') {
            deletes.add(request);
            if (deleteStatus != 204) {
              return _json(<String, dynamic>{
                'error': 'The workspace path cannot be accessed.',
              }, deleteStatus);
            }
            dirDeleted = true;
            return http.Response('', 204);
          }
          final String? folder = request.url.queryParameters['path'];
          if (folder == 'dir') {
            return _json(<Object>[_entry('dir/b.md')]);
          }
          if (folder == 'copies') {
            return _json(<Object>[if (copied) _entry('copies/a.md')]);
          }
          return _json(<Object>[
            if (!dirDeleted) _entry('dir', dir: true),
            _entry('a.md'),
            _entry('copies', dir: true),
          ]);
        }
        return _json(<dynamic>[]);
      }),
    ),
    socket: _FakeSocket(),
  );
}

Future<void> _settle(WidgetTester tester) async {
  for (int i = 0; i < 30; i++) {
    await tester.pump(const Duration(milliseconds: 10));
  }
}

Future<T> _drive<T>(WidgetTester tester, Future<T> future) async {
  await _settle(tester);
  return future;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => FlutterSecureStorage.setMockInitialValues(<String, String>{}));

  Future<DashboardController> connected(
    WidgetTester tester,
    _FilesEngine engine,
  ) async {
    final DashboardController controller = DashboardController(
      ({Uri? explicitEndpoint, String? explicitToken}) async =>
          engine.repository(),
    );
    unawaited(controller.load());
    await _settle(tester);
    expect(controller.isConnected, isTrue);
    expect(controller.activeWorkspace?.uuid, 'w');
    await _drive(tester, controller.loadDirectory(0, ''));
    await _drive(tester, controller.loadDirectory(0, 'dir'));
    controller
      ..setDirectoryExpanded(0, 'dir', true)
      ..selectFileTreeNode(0, 'dir/b.md', isDirectory: false);
    return controller;
  }

  testWidgets('deleting a folder calls the engine and forgets the folder', (
    WidgetTester tester,
  ) async {
    final _FilesEngine engine = _FilesEngine();
    final DashboardController controller = await connected(tester, engine);
    expect(controller.directoryEntries(0, 'dir'), isNotNull);

    final Object? failure = await _drive(
      tester,
      controller.deleteWorkspaceNode(rootIndex: 0, path: 'dir', isDirectory: true),
    );

    expect(failure, isNull);
    expect(engine.deletes, hasLength(1));
    expect(engine.deletes.single.url.queryParameters, <String, String>{
      'rootIndex': '0',
      'path': 'dir',
    });
    // The parent was listed again and no longer has the folder.
    expect(
      controller.directoryEntries(0, '')!.map((WorkspaceFileEntry e) => e.relativePath),
      unorderedEquals(<String>['copies', 'a.md']),
    );
    // Nothing still points into the deleted folder.
    expect(controller.directoryEntries(0, 'dir'), isNull);
    expect(controller.selectedFileTreeNode, isNull);
    expect(controller.isDirectoryExpanded(0, 'dir'), isFalse);
    expect(controller.isMovingWorkspaceNode, isFalse);

    controller.dispose();
    await tester.pump();
  });

  testWidgets('copy and paste send the selected source and select the copy', (
    WidgetTester tester,
  ) async {
    final _FilesEngine engine = _FilesEngine();
    final DashboardController controller = await connected(tester, engine);
    controller.selectFileTreeNode(0, 'a.md', isDirectory: false);
    expect(controller.copySelectedWorkspaceNode(), isTrue);
    expect(controller.copiedWorkspaceNode?.path, 'a.md');

    controller.selectFileTreeNode(0, 'copies', isDirectory: true);
    final Object? failure = await _drive(tester, controller.pasteWorkspaceNode());

    expect(failure, isNull);
    expect(engine.copies, hasLength(1));
    expect(jsonDecode(engine.copies.single.body), <String, dynamic>{
      'sourceRootIndex': 0,
      'sourcePath': 'a.md',
      'destinationRootIndex': 0,
      'destinationPath': 'copies',
    });
    expect(controller.selectedFileTreeNode?.path, 'copies/a.md');
    expect(controller.selectedFileTreeNode?.isDirectory, isFalse);
    expect(
      controller.directoryEntries(0, 'copies')!.map((WorkspaceFileEntry e) => e.relativePath),
      <String>['copies/a.md'],
    );
    // The source stays copied so it can be pasted somewhere else.
    expect(controller.copiedWorkspaceNode?.path, 'a.md');

    controller.dispose();
    await tester.pump();
  });

  testWidgets('paste rejects failure and impossible destinations without losing copy', (
    WidgetTester tester,
  ) async {
    final _FilesEngine engine = _FilesEngine()..copyStatus = 409;
    final DashboardController controller = await connected(tester, engine);
    controller
      ..selectFileTreeNode(0, 'a.md', isDirectory: false)
      ..copySelectedWorkspaceNode()
      ..selectFileTreeNode(0, 'copies', isDirectory: true);
    final Object? failure = await _drive(tester, controller.pasteWorkspaceNode());
    expect(failure, isA<EngineApiException>());
    expect(controller.copiedWorkspaceNode?.path, 'a.md');
    expect(controller.selectedFileTreeNode?.path, 'copies');

    controller.selectFileTreeNode(0, 'dir', isDirectory: true);
    expect(controller.copySelectedWorkspaceNode(), isTrue);
    controller.selectFileTreeNode(0, 'dir', isDirectory: true);
    expect(controller.canPasteWorkspaceNode, isFalse);
    expect(await controller.pasteWorkspaceNode(), isNull);
    expect(engine.copies, hasLength(1));

    controller.dispose();
    await tester.pump();
  });

  testWidgets('deleting the copied source clears the copy reference', (
    WidgetTester tester,
  ) async {
    final _FilesEngine engine = _FilesEngine();
    final DashboardController controller = await connected(tester, engine);
    controller
      ..selectFileTreeNode(0, 'dir', isDirectory: true)
      ..copySelectedWorkspaceNode();
    expect(controller.copiedWorkspaceNode, isNotNull);
    await _drive(tester, controller.deleteWorkspaceNode(
      rootIndex: 0,
      path: 'dir',
      isDirectory: true,
    ));
    expect(controller.copiedWorkspaceNode, isNull);

    controller.dispose();
    await tester.pump();
  });

  testWidgets('a refused delete returns the error and keeps everything', (
    WidgetTester tester,
  ) async {
    final _FilesEngine engine = _FilesEngine()..deleteStatus = 403;
    final DashboardController controller = await connected(tester, engine);

    final Object? failure = await _drive(
      tester,
      controller.deleteWorkspaceNode(rootIndex: 0, path: 'dir', isDirectory: true),
    );

    expect(failure, isA<EngineApiException>());
    expect(controller.directoryEntries(0, 'dir'), isNotNull);
    expect(controller.selectedFileTreeNode?.path, 'dir/b.md');
    expect(controller.isDirectoryExpanded(0, 'dir'), isTrue);
    expect(controller.isMovingWorkspaceNode, isFalse);

    controller.dispose();
    await tester.pump();
  });
}
