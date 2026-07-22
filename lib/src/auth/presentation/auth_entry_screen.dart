import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'auth_entry_mode.dart';
import 'create_account_form_panel.dart';
import 'sign_in_form_panel.dart';

/// Logged-out entry with peer Sign in / Create account segments above the fold.
class AuthEntryScreen extends ConsumerStatefulWidget {
  /// When set, skips preference loading and opens this mode immediately.
  final AuthEntryMode? initialMode;
  final String? initialEmail;
  final bool showRestorePrompt;

  /// Optional override for tests; defaults to [loadPreferredAuthEntryMode].
  final Future<AuthEntryMode> Function()? loadPreferredMode;

  /// Optional override for tests; defaults to [persistAuthEntryMode].
  final Future<void> Function(AuthEntryMode mode)? persistMode;

  const AuthEntryScreen({
    super.key,
    this.initialMode,
    this.initialEmail,
    this.showRestorePrompt = false,
    this.loadPreferredMode,
    this.persistMode,
  });

  @override
  ConsumerState<AuthEntryScreen> createState() => AuthEntryScreenState();
}

@visibleForTesting
class AuthEntryScreenState extends ConsumerState<AuthEntryScreen> {
  AuthEntryMode? _mode;
  bool _loadingPreference = true;

  AuthEntryMode get currentMode =>
      _mode ?? widget.initialMode ?? AuthEntryMode.createAccount;

  @override
  void initState() {
    super.initState();
    _resolveInitialMode();
  }

  Future<void> _resolveInitialMode() async {
    if (widget.initialMode != null) {
      setState(() {
        _mode = widget.initialMode;
        _loadingPreference = false;
      });
      return;
    }

    final preferred =
        await (widget.loadPreferredMode?.call() ??
            loadPreferredAuthEntryMode());
    if (!mounted) return;
    setState(() {
      _mode = preferred;
      _loadingPreference = false;
    });
  }

  void selectMode(AuthEntryMode mode) {
    if (_mode == mode) return;
    setState(() => _mode = mode);
  }

  Future<void> _rememberSuccessfulMode(AuthEntryMode mode) async {
    final persist = widget.persistMode ?? persistAuthEntryMode;
    await persist(mode);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final mode = currentMode;
    final subtitle = mode == AuthEntryMode.createAccount
        ? 'Track buy-ins, cash-outs, and settlements with your group.'
        : 'Welcome back — sign in to continue.';

    return Scaffold(
      resizeToAvoidBottomInset: true,
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 480),
              child: Card(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Icon(Icons.casino, size: 72, color: scheme.primary),
                      const SizedBox(height: 12),
                      Text(
                        'Poker Ledger',
                        style: Theme.of(context).textTheme.headlineMedium
                            ?.copyWith(fontWeight: FontWeight.bold),
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 8),
                      Text(
                        subtitle,
                        style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 24),
                      if (_loadingPreference)
                        const Padding(
                          padding: EdgeInsets.symmetric(vertical: 48),
                          child: Center(child: CircularProgressIndicator()),
                        )
                      else ...[
                        LayoutBuilder(
                          builder: (context, constraints) {
                            final compact = constraints.maxWidth < 360;
                            return SegmentedButton<AuthEntryMode>(
                              segments: [
                                const ButtonSegment<AuthEntryMode>(
                                  value: AuthEntryMode.signIn,
                                  label: Text('Sign in'),
                                  tooltip: 'Sign in',
                                ),
                                ButtonSegment<AuthEntryMode>(
                                  value: AuthEntryMode.createAccount,
                                  label: Text(
                                    compact ? 'Create' : 'Create account',
                                  ),
                                  tooltip: 'Create account',
                                ),
                              ],
                              selected: {mode},
                              showSelectedIcon: false,
                              onSelectionChanged: (selection) {
                                if (selection.isEmpty) return;
                                selectMode(selection.first);
                              },
                              style: ButtonStyle(
                                visualDensity: VisualDensity.standard,
                                tapTargetSize: MaterialTapTargetSize.padded,
                                minimumSize: WidgetStateProperty.all(
                                  const Size(0, 48),
                                ),
                              ),
                            );
                          },
                        ),
                        const SizedBox(height: 24),
                        AnimatedSwitcher(
                          duration: const Duration(milliseconds: 220),
                          switchInCurve: Curves.easeOut,
                          switchOutCurve: Curves.easeIn,
                          child: KeyedSubtree(
                            key: ValueKey(mode),
                            child: mode == AuthEntryMode.signIn
                                ? SignInFormPanel(
                                    initialEmail: widget.initialEmail,
                                    showRestorePrompt: widget.showRestorePrompt,
                                    onSignedIn: () => _rememberSuccessfulMode(
                                      AuthEntryMode.signIn,
                                    ),
                                    onSwitchToCreateAccount: () =>
                                        selectMode(AuthEntryMode.createAccount),
                                  )
                                : CreateAccountFormPanel(
                                    onAccountCreated: () =>
                                        _rememberSuccessfulMode(
                                          AuthEntryMode.createAccount,
                                        ),
                                    onSwitchToSignIn: () =>
                                        selectMode(AuthEntryMode.signIn),
                                  ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
