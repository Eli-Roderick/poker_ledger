import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../providers/auth_providers.dart';
import '../providers/app_settings_providers.dart';
import '../data/admin_config.dart';
import '../../routing/app_shell.dart';
import '../../migration/data/migration_service.dart';
import '../../migration/presentation/migration_screen.dart';
import '../../tutorial/interactive_tutorial.dart';
import '../../theme/theme_provider.dart';
import 'login_screen.dart';
import 'maintenance_screen.dart';

/// Provider to check if user has completed the tutorial
final tutorialCompletedProvider = FutureProvider<bool>((ref) async {
  final user = ref.watch(currentUserProvider);
  if (user == null) return true; // No user, skip tutorial
  
  final data = await Supabase.instance.client
      .from('profiles')
      .select('tutorial_completed')
      .eq('id', user.id)
      .maybeSingle();
  
  return data?['tutorial_completed'] as bool? ?? false;
});

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
    final maintenanceAsync = ref.watch(maintenanceModeProvider);

    return authState.when(
      data: (state) {
        if (state.session != null) {
          final userId = state.session!.user.id;
          
          // Reload theme settings when user logs in
          ref.read(themeModeProvider.notifier).reload();
          
          // Check maintenance mode - only admins can access
          final maintenanceEnabled = maintenanceAsync.valueOrNull ?? false;
          if (maintenanceEnabled && !AdminConfig.isAdmin(userId)) {
            return const MaintenanceScreen();
          }
          
          // User is logged in - check if migration needed
          if (!_checkedLocalData) {
            return const Scaffold(
              body: Center(child: CircularProgressIndicator()),
            );
          }
          if (_hasLocalData == true) {
            return const MigrationScreen();
          }
          
          // Check if tutorial is needed for new users
          final tutorialAsync = ref.watch(tutorialCompletedProvider);
          return tutorialAsync.when(
            data: (completed) {
              if (!completed) {
                // Show interactive tutorial for new users
                return const InteractiveTutorial();
              }
              return const AppShell();
            },
            loading: () => const Scaffold(
              body: Center(child: CircularProgressIndicator()),
            ),
            error: (_, __) => const AppShell(), // Skip tutorial on error
          );
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
