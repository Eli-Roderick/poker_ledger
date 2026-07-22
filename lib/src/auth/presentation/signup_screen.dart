import 'package:flutter/material.dart';

import 'auth_entry_mode.dart';
import 'auth_entry_screen.dart';

/// Compatibility wrapper that opens the shared auth entry on Create account.
class SignupScreen extends StatelessWidget {
  const SignupScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return const AuthEntryScreen(initialMode: AuthEntryMode.createAccount);
  }
}
