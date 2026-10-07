import 'dart:async';
import 'dart:convert';

import 'package:core_business_logic/core_business_logic.dart';
import 'package:flutter/foundation.dart';

enum AccountStatus { initializing, anonymous, authenticated }

typedef EngineClientProvider = FutureOr<RestEngineClient?> Function();

final class AccountController extends ChangeNotifier {
  AccountController({required this.clientProvider});

  final EngineClientProvider clientProvider;

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

  Future<bool> signIn({required String email, required String password}) =>
      _performSessionAction(
        (RestEngineClient client) =>
            client.login(email: email.trim(), password: password),
      );

  Future<String?> requestSignupCode({required String email}) => _performMessage(
    (RestEngineClient client) => client.requestSignupCode(email: email.trim()),
  );

  Future<bool> completeSignup({
    required String email,
    required String code,
    required String password,
    String? displayName,
  }) => _performSessionAction(
    (RestEngineClient client) => client.completeSignup(
      email: email.trim(),
      code: code.trim(),
      password: password,
      displayName: displayName,
    ),
  );

  Future<void> signOut() async {
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
