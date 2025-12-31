import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/auth_providers.dart';
import '../../routing/app_shell.dart';
import '../../migration/data/migration_service.dart';
import '../../migration/presentation/migration_screen.dart';
import 'login_screen.dart';

class AuthGate extends ConsumerStatefulWidget {
  const AuthGate({super.key});

  @override
  ConsumerState<AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends ConsumerState<AuthGate> {
  bool? _hasLocalData;
  bool _checkedLocalData = false;

  @override
  void initState() {
    super.initState();
    _checkLocalData();
  }

  Future<void> _checkLocalData() async {
    final hasData = await MigrationService.hasLocalData();
    setState(() {
      _hasLocalData = hasData;
      _checkedLocalData = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    final authState = ref.watch(authStateProvider);

    return authState.when(
      data: (state) {
        if (state.session != null) {
          // User is logged in - check if migration needed
          if (!_checkedLocalData) {
            return const Scaffold(
              body: Center(child: CircularProgressIndicator()),
            );
          }
          if (_hasLocalData == true) {
            return const MigrationScreen();
          }
          return const AppShell();
        }
        return const LoginScreen();
      },
      loading: () => const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      ),
      error: (error, stack) => Scaffold(
        body: Center(child: Text('Error: $error')),
      ),
    );
  }
}
