import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/auth_repository.dart';
import '../providers/auth_providers.dart';
import '../utils/auth_error_formatter.dart';
import 'forgot_password_screen.dart';

/// Sign-in fields and actions used by [AuthEntryScreen].
class SignInFormPanel extends ConsumerStatefulWidget {
  final String? initialEmail;
  final bool showRestorePrompt;
  final VoidCallback? onSignedIn;
  final VoidCallback? onSwitchToCreateAccount;

  const SignInFormPanel({
    super.key,
    this.initialEmail,
    this.showRestorePrompt = false,
    this.onSignedIn,
    this.onSwitchToCreateAccount,
  });

  @override
  ConsumerState<SignInFormPanel> createState() => _SignInFormPanelState();
}

class _SignInFormPanelState extends ConsumerState<SignInFormPanel> {
  final _formKey = GlobalKey<FormState>();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _isLoading = false;
  String? _errorMessage;
  bool _obscurePassword = true;
  DeletedAccountInfo? _deletedAccountInfo;

  @override
  void initState() {
    super.initState();
    if (widget.initialEmail != null) {
      _emailController.text = widget.initialEmail!;
    }
    if (widget.showRestorePrompt) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        setState(() {
          _errorMessage =
              'Enter your password and click "Restore Account" to restore '
              'your deleted account.';
          _deletedAccountInfo = DeletedAccountInfo(
            userId: '',
            deletedAt: DateTime.now(),
            deletionScheduledAt: DateTime.now().add(const Duration(days: 30)),
          );
        });
      });
    }
  }

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _signIn() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() {
      _isLoading = true;
      _errorMessage = null;
      _deletedAccountInfo = null;
    });

    try {
      final authRepo = ref.read(authRepositoryProvider);
      await authRepo.signIn(
        email: _emailController.text.trim(),
        password: _passwordController.text,
      );
      widget.onSignedIn?.call();
    } on AccountDeletedException catch (e) {
      setState(() {
        _errorMessage = e.message;
        _deletedAccountInfo = e.accountInfo;
      });
    } catch (e) {
      setState(() {
        _errorMessage = formatAuthError(e);
      });
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  Future<void> _restoreAccount() async {
    if (_deletedAccountInfo == null) return;

    final email = _emailController.text.trim();
    final password = _passwordController.text;

    if (password.isEmpty) {
      setState(() {
        _errorMessage = 'Please enter your password to restore your account';
      });
      return;
    }

    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final authRepo = ref.read(authRepositoryProvider);
      await authRepo.restoreDeletedAccount(email, password);

      setState(() => _deletedAccountInfo = null);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Account restored! Signing you in...')),
        );
      }

      await Future.delayed(const Duration(seconds: 1));

      try {
        await authRepo.signIn(email: email, password: password);
      } catch (_) {
        await Future.delayed(const Duration(seconds: 1));
        await authRepo.signIn(email: email, password: password);
      }
      widget.onSignedIn?.call();
    } catch (e) {
      setState(() {
        _errorMessage = formatAuthError(e);
      });
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return AutofillGroup(
      child: Form(
        key: _formKey,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (_errorMessage != null)
              Container(
                padding: const EdgeInsets.all(12),
                margin: const EdgeInsets.only(bottom: 16),
                decoration: BoxDecoration(
                  color: _deletedAccountInfo != null
                      ? Colors.orange.shade50
                      : scheme.errorContainer.withValues(alpha: 0.35),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: _deletedAccountInfo != null
                        ? Colors.orange.shade200
                        : scheme.error.withValues(alpha: 0.4),
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _errorMessage!,
                      style: TextStyle(
                        color: _deletedAccountInfo != null
                            ? Colors.orange.shade700
                            : scheme.error,
                      ),
                    ),
                    if (_deletedAccountInfo != null) ...[
                      const SizedBox(height: 8),
                      SizedBox(
                        width: double.infinity,
                        child: OutlinedButton(
                          onPressed: _isLoading ? null : _restoreAccount,
                          style: OutlinedButton.styleFrom(
                            minimumSize: const Size.fromHeight(48),
                            foregroundColor: Colors.orange.shade700,
                            side: BorderSide(color: Colors.orange.shade400),
                          ),
                          child: const Text('Restore Account'),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            TextFormField(
              controller: _emailController,
              enabled: !_isLoading,
              keyboardType: TextInputType.emailAddress,
              textInputAction: TextInputAction.next,
              autofillHints: const [
                AutofillHints.email,
                AutofillHints.username,
              ],
              decoration: const InputDecoration(
                labelText: 'Email',
                prefixIcon: Icon(Icons.email_outlined),
                border: OutlineInputBorder(),
              ),
              validator: (value) {
                if (value == null || value.isEmpty) {
                  return 'Please enter your email';
                }
                if (!value.contains('@')) {
                  return 'Please enter a valid email';
                }
                return null;
              },
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _passwordController,
              enabled: !_isLoading,
              obscureText: _obscurePassword,
              textInputAction: TextInputAction.done,
              autofillHints: const [AutofillHints.password],
              onFieldSubmitted: (_) => _signIn(),
              decoration: InputDecoration(
                labelText: 'Password',
                prefixIcon: const Icon(Icons.lock_outlined),
                border: const OutlineInputBorder(),
                suffixIcon: IconButton(
                  tooltip: _obscurePassword ? 'Show password' : 'Hide password',
                  icon: Icon(
                    _obscurePassword
                        ? Icons.visibility_outlined
                        : Icons.visibility_off_outlined,
                  ),
                  onPressed: () =>
                      setState(() => _obscurePassword = !_obscurePassword),
                ),
              ),
              validator: (value) {
                if (value == null || value.isEmpty) {
                  return 'Please enter your password';
                }
                return null;
              },
            ),
            const SizedBox(height: 4),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: _isLoading
                    ? null
                    : () {
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (context) => const ForgotPasswordScreen(),
                          ),
                        );
                      },
                child: const Text('Forgot password?'),
              ),
            ),
            const SizedBox(height: 8),
            FilledButton(
              onPressed: _isLoading ? null : _signIn,
              style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(48),
              ),
              child: _isLoading
                  ? const SizedBox(
                      height: 20,
                      width: 20,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : const Text('Sign in'),
            ),
            if (widget.onSwitchToCreateAccount != null) ...[
              const SizedBox(height: 8),
              TextButton(
                onPressed: _isLoading ? null : widget.onSwitchToCreateAccount,
                child: const Text('New here? Create account'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
