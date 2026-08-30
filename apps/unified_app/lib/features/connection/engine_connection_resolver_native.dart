import 'dart:convert';
import 'dart:io';

import 'package:core_business_logic/core_business_logic.dart';

const Duration _healthTimeout = Duration(seconds: 2);
const EngineRuntimeInfo _developmentRuntime = EngineRuntimeInfo(
  host: '127.0.0.1',
  port: 55681,
  token: 'subconscious-dev-token',
  pid: 0,
  version: 'development',
);

Future<EngineRepository?> resolveEngineRepository({
  required Uri? explicitEndpoint,
  required String explicitToken,
  required bool preferDev,
}) async {
  Object? discoveryError;
  final String? directory = _dataDirectory(preferDev);
  if (directory != null) {
    try {
      final EngineRuntimeInfo runtime = await EngineDiscovery(
        loader: _FileRuntimeInfoLoader(directory),
        healthProbe: _isReachable,
      ).discover();
      return _repositoryFromRuntime(runtime);
    } on Object catch (error) {
      discoveryError = error;
    }
  }

  if (preferDev && await _isReachable(_developmentRuntime)) {
    return _repositoryFromRuntime(_developmentRuntime);
  }

  final EngineRepository? explicit = _repositoryFromExplicit(
    explicitEndpoint,
    explicitToken,
  );
  if (explicit != null) return explicit;
  if (discoveryError != null) throw discoveryError;
  return null;
}

Future<bool> _isReachable(EngineRuntimeInfo runtime) async {
  final RestEngineClient client = RestEngineClient(
    baseUri: runtime.httpUri,
    token: runtime.token,
  );
  try {
    await client.health().timeout(_healthTimeout);
    return true;
  } on Object {
    return false;
  } finally {
    await client.close();
  }
}

EngineRepository _repositoryFromRuntime(EngineRuntimeInfo runtime) =>
    EngineRepository(
      rest: RestEngineClient(baseUri: runtime.httpUri, token: runtime.token),
      socket: WebSocketEngineClient(endpoint: runtime.webSocketUri),
    );

EngineRepository? _repositoryFromExplicit(Uri? endpoint, String token) {
  if (endpoint == null || endpoint.host.isEmpty || token.isEmpty) return null;
  return EngineRepository(
    rest: RestEngineClient(
      baseUri: endpoint.replace(
        path: '/api/v1/',
        queryParameters: const <String, String>{},
      ),
      token: token,
    ),
    socket: WebSocketEngineClient(
      endpoint: endpoint.replace(
        scheme: endpoint.scheme == 'https' ? 'wss' : 'ws',
        path: '/api/v1/events',
        queryParameters: <String, String>{'token': token},
      ),
    ),
  );
}

String? _dataDirectory(bool dev) {
  final Map<String, String> environment = Platform.environment;
  String? baseDirectory;
  if (Platform.isWindows) {
    baseDirectory = environment['APPDATA'];
    final String? userProfile = environment['USERPROFILE'];
    baseDirectory ??= userProfile == null
        ? null
        : _join(_join(userProfile, 'AppData'), 'Roaming');
    if (baseDirectory != null) {
      baseDirectory = _join(baseDirectory, 'Subconscious');
    }
  } else if (Platform.isMacOS) {
    final String? home = environment['HOME'];
    if (home != null) {
      baseDirectory = _join(
        _join(_join(home, 'Library'), 'Application Support'),
        'Subconscious',
      );
    }
  } else if (Platform.isLinux) {
    final String? home = environment['HOME'];
    baseDirectory = environment['XDG_CONFIG_HOME'];
    baseDirectory ??= home == null ? null : _join(home, '.config');
    if (baseDirectory != null) {
      baseDirectory = _join(baseDirectory, 'subconscious');
    }
  }
  if (baseDirectory == null) return null;
  return dev ? '$baseDirectory-dev' : baseDirectory;
}

String _join(String parent, String child) =>
    '$parent${Platform.pathSeparator}$child';

final class _FileRuntimeInfoLoader implements RuntimeInfoLoader {
  const _FileRuntimeInfoLoader(this.directory);

  final String directory;

  @override
  Future<EngineRuntimeInfo?> load() async {
    try {
      final String contents = await File(_join(directory, 'runtime.json'))
          .readAsString();
      final Object? decoded = jsonDecode(contents);
      if (decoded is! Map<Object?, Object?>) return null;
      return EngineRuntimeInfo.fromJson(decoded.cast<String, dynamic>());
    } on FileSystemException {
      return null;
    } on FormatException {
      return null;
    } on TypeError {
      return null;
    }
  }
}
