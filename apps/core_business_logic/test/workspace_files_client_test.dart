import 'dart:convert';

import 'package:core_business_logic/core_business_logic.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

void main() {
  test('deleteWorkspacePath sends DELETE with the root and path', () async {
    final List<http.Request> seen = <http.Request>[];
    final RestEngineClient client = RestEngineClient(
      baseUri: Uri.parse('http://127.0.0.1:1/api/v1/'),
      token: 't',
      client: MockClient((http.Request request) async {
        seen.add(request);
        return http.Response('', 204);
      }),
    );
    await client.deleteWorkspacePath(
      workspaceUuid: 'w 1',
      rootIndex: 2,
      path: 'dir/a b.md',
    );
    expect(seen.single.method, 'DELETE');
    expect(seen.single.url.path, '/api/v1/workspaces/w%201/files');
    expect(seen.single.url.queryParameters, <String, String>{
      'rootIndex': '2',
      'path': 'dir/a b.md',
    });
    expect(seen.single.headers['Authorization'], 'Bearer t');
  });

  test('deleteWorkspacePath surfaces engine errors', () async {
    final RestEngineClient client = RestEngineClient(
      baseUri: Uri.parse('http://127.0.0.1:1/api/v1/'),
      token: 't',
      client: MockClient(
        (http.Request request) async => http.Response(
          '{"error":"The requested workspace path does not exist."}',
          404,
          headers: <String, String>{'content-type': 'application/json'},
        ),
      ),
    );
    await expectLater(
      client.deleteWorkspacePath(workspaceUuid: 'w', rootIndex: 0, path: 'x'),
      throwsA(
        isA<EngineApiException>().having(
          (EngineApiException e) => e.statusCode,
          'statusCode',
          404,
        ),
      ),
    );
  });

  test('copyWorkspacePath sends a copy request and returns the copied entry', () async {
  final List<http.Request> seen = <http.Request>[];
  final RestEngineClient client = RestEngineClient(
    baseUri: Uri.parse('http://127.0.0.1:1/api/v1/'),
    token: 't',
    client: MockClient((http.Request request) async {
      seen.add(request);
      return http.Response(
        '{"name":"note.md","relativePath":"copies/note.md","isDirectory":false}',
        200,
        headers: <String, String>{'content-type': 'application/json'},
      );
    }),
  );
  final WorkspaceFileEntry copied = await client.copyWorkspacePath(
    workspaceUuid: 'w 1',
    sourceRootIndex: 0,
    sourcePath: 'notes/note.md',
    destinationRootIndex: 0,
    destinationPath: 'copies',
  );
  expect(copied.relativePath, 'copies/note.md');
  expect(seen.single.method, 'POST');
  expect(seen.single.url.path, '/api/v1/workspaces/w%201/files/copy');
  expect(seen.single.headers['Authorization'], 'Bearer t');
  expect(jsonDecode(seen.single.body), <String, dynamic>{
    'sourceRootIndex': 0,
    'sourcePath': 'notes/note.md',
    'destinationRootIndex': 0,
    'destinationPath': 'copies',
  });
  });
}
