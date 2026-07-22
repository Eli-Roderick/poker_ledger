import 'package:flutter/material.dart';

import 'auth_entry_mode.dart';
import 'auth_entry_screen.dart';

/// Compatibility wrapper that opens the shared auth entry on Sign in.
class LoginScreen extends StatelessWidget {
  final String? initialEmail;
  final bool showRestorePrompt;

  const LoginScreen({
    super.key,
    this.initialEmail,
    this.showRestorePrompt = false,
  });

  @override
  Widget build(BuildContext context) {
    return AuthEntryScreen(
      initialMode: AuthEntryMode.signIn,
      initialEmail: initialEmail,
      showRestorePrompt: showRestorePrompt,
    );
  }
}
