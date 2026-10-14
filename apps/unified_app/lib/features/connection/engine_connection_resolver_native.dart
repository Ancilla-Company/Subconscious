import 'dart:convert';
import 'dart:io';

import 'package:core_business_logic/core_business_logic.dart';

import '../hive/hive_repository_resolver.dart';

const Duration _healthTimeout = Duration(seconds: 2);
const EngineRuntimeInfo _developmentRuntime = EngineRuntimeInfo(
  host: '127.0.0.1',
  port: 50505,
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
  final String? directory = engineDataDirectory(preferDev: preferDev);
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

  final EngineRepository? explicit = _repositoryFromExplicit(
    explicitEndpoint,
    explicitToken,
  );
  if (explicit != null) return explicit;

  if (preferDev && await _isReachable(_developmentRuntime)) {
    return _repositoryFromRuntime(_developmentRuntime);
  }
  // No local engine is reachable: if signed in to the server, use a home
  // engine from the node list over WebRTC (webrtc.md section 9).
  final EngineRepository? remote = await resolveHiveRepository();
  if (remote != null) return remote;
  if (discoveryError != null) throw discoveryError;
  return null;
}

Future<int?> discoverLocalEnginePort({required bool preferDev}) async {
  final String? directory = engineDataDirectory(preferDev: preferDev);
  if (directory != null) {
    try {
      final EngineRuntimeInfo runtime = await EngineDiscovery(
        loader: _FileRuntimeInfoLoader(directory),
        healthProbe: _isReachable,
      ).discover();
      return runtime.port;
    } on Object {
      // Fall through to the stable development endpoint when requested.
    }
  }
  if (preferDev && await _isReachable(_developmentRuntime)) {
    return _developmentRuntime.port;
  }
  return null;
}

Future<Uri?> discoverLocalEngineLanEndpoint({required bool preferDev}) async {
  final int? port = await discoverLocalEnginePort(preferDev: preferDev);
  if (port == null) return null;
  try {
    final List<String> candidates = <String>[
      for (final NetworkInterface interface in await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
        includeLinkLocal: false,
      ))
        for (final InternetAddress address in interface.addresses)
          if (!address.isLoopback && !address.isLinkLocal) address.address,
    ]..sort();
    if (candidates.isEmpty) return null;
    return Uri(scheme: 'http', host: candidates.first, port: port);
  } on SocketException {
    return null;
  }
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

String? engineDataDirectory({required bool preferDev}) {
  final bool dev = preferDev;
  final Map<String, String> environment = Platform.environment;
  String? baseDirectory;
  if (Platform.isWindows) {
    final String? applicationData = environment['APPDATA'];
    if (applicationData != null && applicationData.trim().isNotEmpty) {
      baseDirectory = _join(applicationData, 'Subconscious');
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

Future<void> openEngineDataDirectory(String path) async {
  final Directory directory = Directory(path);
  if (!await directory.exists()) {
    throw FileSystemException(
      'The engine data directory does not exist.',
      path,
    );
  }
  if (Platform.isWindows) {
    await Process.start('explorer.exe', <String>[path], runInShell: false);
    return;
  }
  if (Platform.isMacOS) {
    await Process.start('open', <String>[path], runInShell: false);
    return;
  }
  if (Platform.isLinux) {
    await Process.start('xdg-open', <String>[path], runInShell: false);
    return;
  }
  throw UnsupportedError('Opening the engine data directory is unavailable.');
}
