import 'dart:async';
import 'dart:convert';

import 'package:core_business_logic/core_business_logic.dart';
import 'package:flutter/foundation.dart';

import '../hive/hive_runtime.dart';

enum AccountStatus { initializing, anonymous, authenticated }

typedef EngineClientProvider = FutureOr<RestEngineClient?> Function();

final class AccountController extends ChangeNotifier {
  /// With [serverRuntime] the controller signs in directly against the
  /// Subconscious server (phones, tablets and the web have no local engine).
  /// Without it, account actions go through the local engine.
  AccountController({
    required this.clientProvider,
    this.serverRuntime,
    this.onSessionChanged,
  }) {
    serverRuntime?.addListener(_syncFromRuntime);
  }

  final EngineClientProvider clientProvider;
  final HiveRuntime? serverRuntime;

  /// Called after a sign-in, sign-up or sign-out so the app can reconnect.
  final FutureOr<void> Function()? onSessionChanged;

  bool get usesServerAccount => serverRuntime != null;

  AccountStatus status = AccountStatus.initializing;
  AccountUser? _user;
  String? error;
  String? notice;
  bool isBusy = false;

  AccountUser? get user => _user;
  bool get isAuthenticated => status == AccountStatus.authenticated;

  String get sidebarTooltip {
    final AccountUser? currentUser = _user;
    if (currentUser == null) return 'Account';
    final String displayName = currentUser.displayName?.trim() ?? '';
    return displayName.isEmpty
        ? currentUser.email
        : '$displayName (${currentUser.email})';
  }

  Future<void> restoreSession() async {
    if (status != AccountStatus.initializing) return;
    final HiveRuntime? server = serverRuntime;
    if (server != null) {
      await server.restore();
      _applyServerSession(server);
      notifyListeners();
      return;
    }
    try {
      final RestEngineClient? client = await clientProvider();
      if (client == null) {
        status = AccountStatus.anonymous;
      } else {
        _applySession(await client.accountSession());
      }
    } on Object catch (caughtError) {
      status = AccountStatus.anonymous;
      error = _messageFor(caughtError);
    }
    notifyListeners();
  }

  Future<bool> signIn({required String email, required String password}) {
    final HiveRuntime? server = serverRuntime;
    if (server != null) {
      return _performServerAction(() async {
        await server.account.loginWithEmail(
          email: email.trim(),
          password: password,
        );
      });
    }
    return _performSessionAction(
      (RestEngineClient client) =>
          client.login(email: email.trim(), password: password),
    );
  }

  Future<String?> requestSignupCode({required String email}) {
    final HiveRuntime? server = serverRuntime;
    if (server != null) {
      return _performServerMessage(
        () => server.account.requestSignupCode(email.trim()),
      );
    }
    return _performMessage(
      (RestEngineClient client) =>
          client.requestSignupCode(email: email.trim()),
    );
  }

  Future<bool> completeSignup({
    required String email,
    required String code,
    required String password,
    String? displayName,
  }) {
    final HiveRuntime? server = serverRuntime;
    if (server != null) {
      return _performServerAction(() async {
        await server.account.completeSignup(
          email: email.trim(),
          code: code.trim(),
          password: password,
          displayName: displayName,
        );
      });
    }
    return _performSessionAction(
      (RestEngineClient client) => client.completeSignup(
        email: email.trim(),
        code: code.trim(),
        password: password,
        displayName: displayName,
      ),
    );
  }

  Future<void> signOut() async {
    final HiveRuntime? server = serverRuntime;
    if (server != null) {
      _user = null;
      status = AccountStatus.anonymous;
      error = null;
      notice = null;
      notifyListeners();
      await server.signOut();
      await _notifySessionChanged();
      return;
    }
    _user = null;
    status = AccountStatus.anonymous;
    error = null;
    notice = null;
    notifyListeners();
    try {
      final RestEngineClient? client = await clientProvider();
      await client?.logout();
    } on Object {
      // The engine clears its local credential before attempting remote logout.
    }
  }

  Future<bool> _performSessionAction(
    Future<AccountSession> Function(RestEngineClient client) action,
  ) async {
    _beginRequest();
    try {
      final RestEngineClient client = await _requiredClient();
      _applySession(await action(client));
      notice = null;
      return true;
    } on Object catch (caughtError) {
      error = _messageFor(caughtError);
      return false;
    } finally {
      isBusy = false;
      notifyListeners();
    }
  }

  Future<String?> _performMessage(
    Future<String> Function(RestEngineClient client) action,
  ) async {
    _beginRequest();
    try {
      notice = await action(await _requiredClient());
      return notice;
    } on Object catch (caughtError) {
      error = _messageFor(caughtError);
      return null;
    } finally {
      isBusy = false;
      notifyListeners();
    }
  }

  /// Server sign-in or sign-up: the account client has already stored the
  /// session, so start the hive (device registration and signalling) and
  /// reconnect to the home engine.
  Future<bool> _performServerAction(Future<void> Function() action) async {
    final HiveRuntime server = serverRuntime!;
    _beginRequest();
    try {
      await action();
      await server.adoptSession();
      _applyServerSession(server);
      notice = null;
      isBusy = false;
      notifyListeners();
      await _notifySessionChanged();
      return true;
    } on Object catch (caughtError) {
      error = _messageFor(caughtError);
      return false;
    } finally {
      isBusy = false;
      notifyListeners();
    }
  }

  Future<String?> _performServerMessage(Future<String> Function() action) async {
    _beginRequest();
    try {
      final String message = await action();
      notice = message;
      return message;
    } on Object catch (caughtError) {
      error = _messageFor(caughtError);
      return null;
    } finally {
      isBusy = false;
      notifyListeners();
    }
  }

  void _applyServerSession(HiveRuntime server) {
    final ServerUser? user = server.account.user;
    if (user == null) {
      _user = null;
      status = AccountStatus.anonymous;
      return;
    }
    _user = AccountUser(
      id: user.id,
      email: user.email,
      displayName: user.displayName,
      connectedProviders: const <String>[],
    );
    status = AccountStatus.authenticated;
  }

  void _syncFromRuntime() {
    final HiveRuntime? server = serverRuntime;
    if (server == null || isBusy || status == AccountStatus.initializing) {
      return;
    }
    final bool signedIn = server.isSignedIn;
    if (signedIn == isAuthenticated) return;
    _applyServerSession(server);
    notifyListeners();
  }

  Future<void> _notifySessionChanged() async {
    try {
      await onSessionChanged?.call();
    } on Object {
      // Reconnect failures are shown by the connection status.
    }
  }

  @override
  void dispose() {
    serverRuntime?.removeListener(_syncFromRuntime);
    super.dispose();
  }

  Future<RestEngineClient> _requiredClient() async {
    final RestEngineClient? client = await clientProvider();
    if (client == null) throw StateError('The local engine is not connected.');
    return client;
  }

  void _applySession(AccountSession session) {
    _user = session.user;
    status = session.authenticated
        ? AccountStatus.authenticated
        : AccountStatus.anonymous;
    notice = session.notice;
  }

  void clearFeedback() {
    if (error == null && notice == null) return;
    error = null;
    notice = null;
    notifyListeners();
  }

  void _beginRequest() {
    error = null;
    notice = null;
    isBusy = true;
    notifyListeners();
  }

  static String _messageFor(Object error) {
    if (error is HiveApiException) return error.message;
    if (error is EngineApiException && error.body != null) {
      try {
        final Object? value = jsonDecode(error.body!);
        if (value is Map && value['error'] is String) {
          return value['error'] as String;
        }
      } on FormatException {
        // Fall through to the engine API error below.
      }
    }
    if (error is FormatException) return error.message;
    if (error is StateError) return error.message.toString();
    return 'Could not reach the local engine. Check that it is running and try again.';
  }
}
