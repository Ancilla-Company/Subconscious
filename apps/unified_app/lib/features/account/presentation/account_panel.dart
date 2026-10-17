import 'dart:async';
import 'dart:convert';

import 'package:core_business_logic/core_business_logic.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../hive/presentation/nodes_page.dart';
import '../account_controller.dart';

final class AccountPanel extends StatelessWidget {
  const AccountPanel({required this.controller, super.key});

  final AccountController controller;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: controller,
    builder: (BuildContext context, Widget? child) {
      final Widget content = switch (controller.status) {
        AccountStatus.initializing => const Center(
          child: CircularProgressIndicator(),
        ),
        AccountStatus.authenticated => _SignedInAccount(controller: controller),
        AccountStatus.anonymous => _AnonymousAccount(controller: controller),
      };
      final ThemeData theme = Theme.of(context);
      return Theme(
        data: _accountPanelTheme(theme),
        child: ColoredBox(
          color: theme.colorScheme.surface,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              SizedBox(
                height: 56,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  child: Align(
                    alignment: Alignment.center,
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 750),
                      child: SizedBox(
                        width: double.infinity,
                        child: Text(
                          'Account',
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(24),
                  child: Align(
                    alignment: Alignment.topCenter,
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 750),
                      child: content,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    },
  );
}

ThemeData _accountPanelTheme(ThemeData base) => base.copyWith(
  filledButtonTheme: FilledButtonThemeData(
    style: _rectangularControlStyle(base.filledButtonTheme.style),
  ),
  textButtonTheme: TextButtonThemeData(
    style: _rectangularControlStyle(base.textButtonTheme.style),
  ),
  segmentedButtonTheme: SegmentedButtonThemeData(
    style: _rectangularControlStyle(base.segmentedButtonTheme.style),
  ),
);

ButtonStyle _rectangularControlStyle(ButtonStyle? inherited) =>
    (inherited ?? const ButtonStyle()).copyWith(
      shape: const WidgetStatePropertyAll<OutlinedBorder>(
        RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(3)),
        ),
      ),
    );

final class _SignedInAccount extends StatelessWidget {
  const _SignedInAccount({required this.controller});

  final AccountController controller;

  @override
  Widget build(BuildContext context) {
    final AccountUser user = controller.user!;
    final String displayName = user.displayName?.trim() ?? '';
    final ThemeData theme = Theme.of(context);
    final Widget avatar = CircleAvatar(
      radius: 28,
      backgroundColor: theme.colorScheme.secondaryContainer,
      foregroundColor: theme.colorScheme.onSecondaryContainer,
      child: const Icon(Icons.person_outline, size: 30),
    );
    final Widget details = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          displayName.isNotEmpty ? displayName : user.email,
          style: theme.textTheme.titleLarge,
        ),
        if (displayName.isNotEmpty) ...<Widget>[
          const SizedBox(height: 4),
          Text(user.email),
        ],
        if (user.connectedProviders.isNotEmpty) ...<Widget>[
          const SizedBox(height: 16),
          Text('Connected providers', style: theme.textTheme.labelLarge),
          const SizedBox(height: 4),
          Text(user.connectedProviders.join(', ')),
        ],
      ],
    );
    final Widget signOutButton = FilledButton.tonalIcon(
      onPressed: controller.isBusy ? null : controller.signOut,
      icon: const Icon(Icons.logout),
      label: const Text('Sign out'),
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        SizedBox(
          width: double.infinity,
          child: Card(
            margin: EdgeInsets.zero,
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: LayoutBuilder(
                builder: (BuildContext context, BoxConstraints constraints) {
                  if (constraints.maxWidth < 520) {
                    return Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        avatar,
                        const SizedBox(width: 16),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: <Widget>[
                              details,
                              const SizedBox(height: 16),
                              signOutButton,
                            ],
                          ),
                        ),
                      ],
                    );
                  }
                  return Row(
                    children: <Widget>[
                      avatar,
                      const SizedBox(width: 16),
                      Expanded(child: details),
                      const SizedBox(width: 20),
                      signOutButton,
                    ],
                  );
                },
              ),
            ),
          ),
        ),
        const SizedBox(height: 24),
        Text('Devices', style: theme.textTheme.titleMedium),
        DevicesSection(account: controller),
      ],
    );
  }
}

final class _AnonymousAccount extends StatefulWidget {
  const _AnonymousAccount({required this.controller});

  final AccountController controller;

  @override
  State<_AnonymousAccount> createState() => _AnonymousAccountState();
}

enum _AccountForm { signIn, signUp }

final class _AnonymousAccountState extends State<_AnonymousAccount> {
  _AccountForm _form = _AccountForm.signIn;
  bool _forgotPassword = false;
  String _resetEmailPrefill = '';

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: <Widget>[
      Text(
        widget.controller.usesServerAccount
            ? 'Sign in to your Subconscious account to reach your engines from this device. Your data stays on your own computers.'
            : 'Sign in to connect this desktop app to your Subconscious account. Your local engine remains private and uses its own joining token.',
      ),
      const SizedBox(height: 20),
      if (_forgotPassword)
        _ForgotPasswordForm(
          controller: widget.controller,
          initialEmail: _resetEmailPrefill,
          onBack: () {
            widget.controller.clearFeedback();
            setState(() => _forgotPassword = false);
          },
        )
      else ...<Widget>[
        SegmentedButton<_AccountForm>(
          segments: const <ButtonSegment<_AccountForm>>[
            ButtonSegment<_AccountForm>(
              value: _AccountForm.signIn,
              label: Text('Sign in'),
            ),
            ButtonSegment<_AccountForm>(
              value: _AccountForm.signUp,
              label: Text('Create account'),
            ),
          ],
          selected: <_AccountForm>{_form},
          onSelectionChanged: (Set<_AccountForm> selection) => setState(() {
            _form = selection.single;
            widget.controller.clearFeedback();
          }),
        ),
        const SizedBox(height: 20),
        if (_form == _AccountForm.signIn)
          _SignInForm(
            controller: widget.controller,
            onForgotPassword: (String email) {
              widget.controller.clearFeedback();
              setState(() {
                _resetEmailPrefill = email;
                _forgotPassword = true;
              });
            },
          )
        else
          _SignupForm(controller: widget.controller),
      ],
    ],
  );
}

final class _SignInForm extends StatefulWidget {
  const _SignInForm({required this.controller, required this.onForgotPassword});

  final AccountController controller;
  final void Function(String email) onForgotPassword;

  @override
  State<_SignInForm> createState() => _SignInFormState();
}

final class _SignInFormState extends State<_SignInForm> {
  final GlobalKey<FormState> _formKey = GlobalKey<FormState>();
  final TextEditingController _email = TextEditingController();
  final TextEditingController _password = TextEditingController();
  bool _obscurePassword = true;

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    final bool succeeded = await widget.controller.signIn(
      email: _email.text,
      password: _password.text,
    );
    if (!succeeded && mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) => Form(
    key: _formKey,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        _EmailField(controller: _email, enabled: !widget.controller.isBusy),
        const SizedBox(height: 12),
        _PasswordField(
          controller: _password,
          enabled: !widget.controller.isBusy,
          obscure: _obscurePassword,
          onToggleObscure: () =>
              setState(() => _obscurePassword = !_obscurePassword),
          onSubmitted: widget.controller.isBusy ? null : _submit,
        ),
        Align(
          alignment: Alignment.centerRight,
          child: TextButton(
            onPressed: widget.controller.isBusy
                ? null
                : () => widget.onForgotPassword(_email.text.trim()),
            child: const Text('Forgot password?'),
          ),
        ),
        const SizedBox(height: 4),
        _FeedbackMessage(controller: widget.controller),
        const SizedBox(height: 8),
        FilledButton(
          onPressed: widget.controller.isBusy ? null : _submit,
          child: Text(widget.controller.isBusy ? 'Signing in…' : 'Sign in'),
        ),
      ],
    ),
  );
}

final class _SignupForm extends StatefulWidget {
  const _SignupForm({required this.controller});

  final AccountController controller;

  @override
  State<_SignupForm> createState() => _SignupFormState();
}

final class _SignupFormState extends State<_SignupForm> {
  static const Duration _resendCooldown = Duration(seconds: 60);

  final GlobalKey<FormState> _formKey = GlobalKey<FormState>();
  final TextEditingController _email = TextEditingController();
  final TextEditingController _code = TextEditingController();
  final TextEditingController _password = TextEditingController();
  final TextEditingController _displayName = TextEditingController();
  Timer? _resendTimer;
  int _secondsUntilResend = 0;
  bool _codeRequested = false;
  bool _obscurePassword = true;

  @override
  void dispose() {
    _resendTimer?.cancel();
    _email.dispose();
    _code.dispose();
    _password.dispose();
    _displayName.dispose();
    super.dispose();
  }

  Future<void> _requestInitialCode() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    final String? message = await widget.controller.requestSignupCode(
      email: _email.text,
    );
    if (message != null && mounted) {
      setState(() {
        _codeRequested = true;
        _startResendCooldown();
      });
    }
  }

  Future<void> _resendCode() async {
    if (_secondsUntilResend > 0 || widget.controller.isBusy) return;
    final String? message = await widget.controller.requestSignupCode(
      email: _email.text,
    );
    if (message != null && mounted) {
      setState(_startResendCooldown);
    }
  }

  void _startResendCooldown() {
    _resendTimer?.cancel();
    _secondsUntilResend = _resendCooldown.inSeconds;
    _resendTimer = Timer.periodic(const Duration(seconds: 1), (Timer timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      if (_secondsUntilResend <= 1) {
        timer.cancel();
        setState(() => _secondsUntilResend = 0);
        return;
      }
      setState(() => _secondsUntilResend--);
    });
  }

  Future<void> _completeSignup() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    final bool succeeded = await widget.controller.completeSignup(
      email: _email.text,
      code: _code.text,
      password: _password.text,
      displayName: _displayName.text,
    );
    if (!succeeded && mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) => Form(
    key: _formKey,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        _EmailField(controller: _email, enabled: !widget.controller.isBusy),
        if (_codeRequested) ...<Widget>[
          const SizedBox(height: 12),
          TextFormField(
            controller: _code,
            enabled: !widget.controller.isBusy,
            keyboardType: TextInputType.number,
            inputFormatters: <TextInputFormatter>[
              FilteringTextInputFormatter.digitsOnly,
            ],
            autocorrect: false,
            enableSuggestions: false,
            textInputAction: TextInputAction.next,
            decoration: const InputDecoration(labelText: 'Verification code'),
            validator: (String? value) => value == null || value.trim().isEmpty
                ? 'Enter the code from your email.'
                : null,
          ),
          const SizedBox(height: 12),
          TextFormField(
            controller: _displayName,
            enabled: !widget.controller.isBusy,
            textInputAction: TextInputAction.next,
            decoration: const InputDecoration(
              labelText: 'Display name (optional)',
            ),
          ),
          const SizedBox(height: 12),
          _PasswordField(
            controller: _password,
            enabled: !widget.controller.isBusy,
            obscure: _obscurePassword,
            onToggleObscure: () =>
                setState(() => _obscurePassword = !_obscurePassword),
          ),
        ],
        const SizedBox(height: 12),
        _FeedbackMessage(controller: widget.controller),
        const SizedBox(height: 8),
        FilledButton(
          onPressed: widget.controller.isBusy
              ? null
              : _codeRequested
              ? _completeSignup
              : _requestInitialCode,
          child: Text(
            widget.controller.isBusy
                ? 'Contacting server…'
                : _codeRequested
                ? 'Create account'
                : 'Send verification code',
          ),
        ),
        if (_codeRequested)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: TextButton(
              onPressed: widget.controller.isBusy || _secondsUntilResend > 0
                  ? null
                  : _resendCode,
              child: Text(
                _secondsUntilResend > 0
                    ? 'Send a new code in ${_secondsUntilResend}s'
                    : 'Send a new code',
              ),
            ),
          ),
      ],
    ),
  );
}

final class _ForgotPasswordForm extends StatefulWidget {
  const _ForgotPasswordForm({
    required this.controller,
    required this.initialEmail,
    required this.onBack,
  });

  final AccountController controller;
  final String initialEmail;
  final VoidCallback onBack;

  @override
  State<_ForgotPasswordForm> createState() => _ForgotPasswordFormState();
}

final class _ForgotPasswordFormState extends State<_ForgotPasswordForm> {
  static const Duration _resendCooldown = Duration(seconds: 60);

  final GlobalKey<FormState> _formKey = GlobalKey<FormState>();
  late final TextEditingController _email = TextEditingController(
    text: widget.initialEmail,
  );
  final TextEditingController _code = TextEditingController();
  final TextEditingController _password = TextEditingController();
  Timer? _resendTimer;
  int _secondsUntilResend = 0;
  bool _codeSent = false;
  bool _obscurePassword = true;

  @override
  void dispose() {
    _resendTimer?.cancel();
    _email.dispose();
    _code.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _sendCode() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    final String? message = await widget.controller.requestPasswordReset(
      email: _email.text,
    );
    if (message != null && mounted) {
      setState(() {
        _codeSent = true;
        _startResendCooldown();
      });
    }
  }

  Future<void> _resendCode() async {
    if (_secondsUntilResend > 0 || widget.controller.isBusy) return;
    final String? message = await widget.controller.requestPasswordReset(
      email: _email.text,
    );
    if (message != null && mounted) {
      setState(_startResendCooldown);
    }
  }

  void _startResendCooldown() {
    _resendTimer?.cancel();
    _secondsUntilResend = _resendCooldown.inSeconds;
    _resendTimer = Timer.periodic(const Duration(seconds: 1), (Timer timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      if (_secondsUntilResend <= 1) {
        timer.cancel();
        setState(() => _secondsUntilResend = 0);
        return;
      }
      setState(() => _secondsUntilResend--);
    });
  }

  void _useDifferentEmail() {
    _resendTimer?.cancel();
    widget.controller.clearFeedback();
    setState(() {
      _codeSent = false;
      _secondsUntilResend = 0;
      _code.clear();
      _password.clear();
    });
  }

  Future<void> _confirm() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    final bool succeeded = await widget.controller.confirmPasswordReset(
      email: _email.text,
      code: _code.text,
      newPassword: _password.text,
    );
    if (!succeeded && mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final bool busy = widget.controller.isBusy;
    return Form(
      key: _formKey,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Semantics(
            header: true,
            child: Text(
              'Reset your password',
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ),
          const SizedBox(height: 12),
          if (!_codeSent)
            _EmailField(controller: _email, enabled: !busy)
          else ...<Widget>[
            Text('Code sent to ${_email.text.trim()}'),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                onPressed: busy ? null : _useDifferentEmail,
                child: const Text('Use a different email'),
              ),
            ),
            const SizedBox(height: 4),
            TextFormField(
              controller: _code,
              enabled: !busy,
              keyboardType: TextInputType.number,
              inputFormatters: <TextInputFormatter>[
                FilteringTextInputFormatter.digitsOnly,
                LengthLimitingTextInputFormatter(12),
              ],
              autofillHints: const <String>[AutofillHints.oneTimeCode],
              autocorrect: false,
              enableSuggestions: false,
              textInputAction: TextInputAction.next,
              decoration: const InputDecoration(labelText: 'Reset code'),
              validator: (String? value) =>
                  value == null || value.trim().isEmpty
                  ? 'Enter the code from your email.'
                  : null,
            ),
            const SizedBox(height: 12),
            _PasswordField(
              controller: _password,
              enabled: !busy,
              obscure: _obscurePassword,
              label: 'New password',
              onToggleObscure: () =>
                  setState(() => _obscurePassword = !_obscurePassword),
              validator: (String? value) {
                final String password = value ?? '';
                if (password.length < 8) return 'Use at least 8 characters.';
                if (utf8.encode(password).length > 72) {
                  return 'Use at most 72 bytes.';
                }
                return null;
              },
              onSubmitted: busy ? null : _confirm,
            ),
          ],
          const SizedBox(height: 12),
          _FeedbackMessage(controller: widget.controller),
          if (_codeSent) ...<Widget>[
            const SizedBox(height: 8),
            Text(
              "No email? Check spam, or wait a few minutes and try again. If it still doesn't arrive, try again in an hour.",
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
          const SizedBox(height: 8),
          FilledButton(
            onPressed: busy ? null : (_codeSent ? _confirm : _sendCode),
            child: Text(
              busy
                  ? 'Contacting server…'
                  : _codeSent
                  ? 'Reset password'
                  : 'Send reset code',
            ),
          ),
          if (_codeSent)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: TextButton(
                onPressed: busy || _secondsUntilResend > 0 ? null : _resendCode,
                child: Text(
                  _secondsUntilResend > 0
                      ? 'Send a new code in ${_secondsUntilResend}s'
                      : 'Send a new code',
                ),
              ),
            ),
          TextButton(
            onPressed: busy ? null : widget.onBack,
            child: const Text('Back to sign in'),
          ),
        ],
      ),
    );
  }
}

final class _EmailField extends StatelessWidget {
  const _EmailField({required this.controller, required this.enabled});

  final TextEditingController controller;
  final bool enabled;

  @override
  Widget build(BuildContext context) => TextFormField(
    controller: controller,
    enabled: enabled,
    keyboardType: TextInputType.emailAddress,
    autocorrect: false,
    enableSuggestions: false,
    textInputAction: TextInputAction.next,
    decoration: const InputDecoration(labelText: 'Email address'),
    validator: (String? value) {
      final String email = value?.trim() ?? '';
      return email.contains('@') && email.contains('.')
          ? null
          : 'Enter a valid email address.';
    },
  );
}

final class _PasswordField extends StatelessWidget {
  const _PasswordField({
    required this.controller,
    required this.enabled,
    required this.obscure,
    required this.onToggleObscure,
    this.label = 'Password',
    this.validator,
    this.onSubmitted,
  });

  final TextEditingController controller;
  final bool enabled;
  final bool obscure;
  final VoidCallback onToggleObscure;
  final String label;
  final String? Function(String?)? validator;
  final VoidCallback? onSubmitted;

  @override
  Widget build(BuildContext context) => TextFormField(
    controller: controller,
    enabled: enabled,
    obscureText: obscure,
    enableSuggestions: false,
    autocorrect: false,
    textInputAction: TextInputAction.done,
    onFieldSubmitted: onSubmitted == null ? null : (_) => onSubmitted!(),
    decoration: InputDecoration(
      labelText: label,
      helperText: 'At least 8 characters',
      suffixIcon: IconButton(
        tooltip: obscure ? 'Show password' : 'Hide password',
        onPressed: enabled ? onToggleObscure : null,
        icon: Icon(
          obscure ? Icons.visibility_outlined : Icons.visibility_off_outlined,
        ),
      ),
    ),
    validator:
        validator ??
        (String? value) =>
            (value?.length ?? 0) < 8 ? 'Use at least 8 characters.' : null,
  );
}

final class _FeedbackMessage extends StatelessWidget {
  const _FeedbackMessage({required this.controller});

  final AccountController controller;

  @override
  Widget build(BuildContext context) {
    final String? message = controller.error ?? controller.notice;
    if (message == null) return const SizedBox.shrink();
    final bool isError = controller.error != null;
    final ColorScheme colors = Theme.of(context).colorScheme;
    return Semantics(
      liveRegion: true,
      container: true,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: isError ? colors.errorContainer : colors.secondaryContainer,
          borderRadius: const BorderRadius.all(Radius.circular(3)),
        ),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Text(
            message,
            style: TextStyle(
              color: isError
                  ? colors.onErrorContainer
                  : colors.onSecondaryContainer,
            ),
          ),
        ),
      ),
    );
  }
}
