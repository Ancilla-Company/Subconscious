import 'dart:async';

import 'package:core_business_logic/core_business_logic.dart';
import 'package:flutter/foundation.dart';

import '../hive/hive_runtime.dart';

enum AccountStatus { initializing, anonymous, authenticated }

typedef EngineClientProvider = FutureOr<RestEngineClient?> Function();

/// Account state for every platform.
///
/// The server [session] is the single source of truth for whether the user is
/// signed in; the Account page and the Devices section both read it. The only
/// difference between platforms is the engine: a thin client (phone, tablet,
/// web) reaches a remote engine over WebRTC, everything else has a local
/// engine, which is signed in with the same credentials right after the
/// server accepts them.
final class AccountController extends ChangeNotifier {
  AccountController({
    required this.session,
    required this.clientProvider,
    this.thinClient = false,
    this.onSessionChanged,
  }) {
    session.addListener(_syncFromSession);
  }

  /// The one server session (sign-in, sign-up, sign-out, devices).
  final HiveRuntime session;

  /// The local engine's client, or null while it is not connected.
  final EngineClientProvider clientProvider;

  /// True on devices with no local engine (they use a remote home engine).
  final bool thinClient;

  /// Called after a sign-in, sign-up or sign-out so the app can reconnect.
  final FutureOr<void> Function()? onSessionChanged;

  /// The server session when this device uses a remote engine, else null.
  HiveRuntime? get serverRuntime => thinClient ? session : null;

  static const String sessionExpiredMessage =
      'Your session expired. Sign in again.';

  bool get usesServerAccount => thinClient;

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
    await session.restore();
    _applySession();
    notifyListeners();
  }

  Future<bool> signIn({required String email, required String password}) {
    final String address = email.trim();
    return _performAction(
      () => session.account.loginWithEmail(email: address, password: password),
      linkEngine: (RestEngineClient client) async {
        await client.login(email: address, password: password);
      },
    );
  }

  Future<String?> requestSignupCode({required String email}) async {
    _beginRequest();
    try {
      final String message = await session.account.requestSignupCode(
        email.trim(),
      );
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

  Future<bool> completeSignup({
    required String email,
    required String code,
    required String password,
    String? displayName,
  }) {
    final String address = email.trim();
    return _performAction(
      () => session.account.completeSignup(
        email: address,
        code: code.trim(),
        password: password,
        displayName: displayName,
      ),
      linkEngine: (RestEngineClient client) async {
        await client.login(email: address, password: password);
      },
    );
  }

  Future<String?> requestPasswordReset({required String email}) async {
    _beginRequest();
    try {
      final String message = await session.account.requestPasswordReset(
        email.trim(),
      );
      notice = message;
      return message;
    } on Object catch (caughtError) {
      error = _resetMessageFor(caughtError);
      return null;
    } finally {
      isBusy = false;
      notifyListeners();
    }
  }

  /// Sets a new password with the emailed [code]; on success the server signs
  /// the user in, exactly like [signIn].
  Future<bool> confirmPasswordReset({
    required String email,
    required String code,
    required String newPassword,
  }) {
    final String address = email.trim();
    return _performAction(
      () => session.account.confirmPasswordReset(
        email: address,
        code: code.trim(),
        newPassword: newPassword,
      ),
      linkEngine: (RestEngineClient client) async {
        await client.login(email: address, password: newPassword);
      },
      messageFor: _resetMessageFor,
    );
  }

  Future<void> signOut() async {
    _user = null;
    status = AccountStatus.anonymous;
    error = null;
    notice = null;
    notifyListeners();
    await session.signOut();
    if (!thinClient) {
      try {
        final RestEngineClient? client = await clientProvider();
        await client?.logout();
      } on Object catch (caughtError) {
        debugPrint('Could not sign the local engine out: $caughtError');
      }
    }
    await _notifySessionChanged();
  }

  /// Signs in (or up) against the server, starts the hive, then signs the
  /// local engine in with the same credentials via [linkEngine]. A local
  /// engine failure never undoes the account sign-in; it is reported in
  /// [notice].
  Future<bool> _performAction(
    Future<void> Function() action, {
    required Future<void> Function(RestEngineClient client) linkEngine,
    String Function(Object error) messageFor = _messageFor,
  }) async {
    _beginRequest();
    try {
      await action();
      await session.adoptSession();
      _applySession();
      if (!session.isSignedIn) {
        // The server accepted the login but rejected the session straight
        // away; do not report success.
        error = messageFor(session.error ?? StateError('Sign-in failed.'));
        return false;
      }
      notice = null;
      if (!thinClient) await _linkEngine(linkEngine);
      isBusy = false;
      notifyListeners();
      await _notifySessionChanged();
      return true;
    } on Object catch (caughtError) {
      error = messageFor(caughtError);
      return false;
    } finally {
      isBusy = false;
      notifyListeners();
    }
  }

  Future<void> _linkEngine(
    Future<void> Function(RestEngineClient client) link,
  ) async {
    try {
      final RestEngineClient? client = await clientProvider();
      if (client == null) {
        notice =
            'Signed in. The local engine is not connected, so it was not '
            'linked to your account yet.';
        return;
      }
      await link(client);
    } on Object catch (caughtError) {
      debugPrint('Could not sign the local engine in: $caughtError');
      notice =
          'Signed in, but the local engine could not be linked to your '
          'account. Try signing out and in again.';
    }
  }

  void _applySession() {
    final ServerUser? user = session.account.user;
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

  void _syncFromSession() {
    if (isBusy || status == AccountStatus.initializing) return;
    if (session.isSignedIn == isAuthenticated) return;
    _applySession();
    final Object? cause = session.error;
    if (!session.isSignedIn &&
        cause is HiveApiException &&
        cause.statusCode == 401) {
      error = sessionExpiredMessage;
    }
    notifyListeners();
  }

  Future<void> _notifySessionChanged() async {
    try {
      await onSessionChanged?.call();
    } on Object catch (caughtError) {
      // Reconnect failures are shown by the connection status.
      debugPrint('Reconnect after an account change failed: $caughtError');
    }
  }

  @override
  void dispose() {
    session.removeListener(_syncFromSession);
    super.dispose();
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

  static String _resetMessageFor(Object error) {
    if (error is HiveApiException) {
      if (error.statusCode == 429) {
        return 'Too many attempts. Wait a few minutes and try again.';
      }
      if (error.statusCode == 400) {
        return '${error.message} Request a new code if it keeps failing.';
      }
    }
    return _messageFor(error);
  }

  static String _messageFor(Object error) {
    if (error is HiveApiException) return error.message;
    if (error is FormatException) return error.message;
    if (error is StateError) return error.message.toString();
    return 'Could not reach the Subconscious server. Check your connection '
        'and try again.';
  }
}
