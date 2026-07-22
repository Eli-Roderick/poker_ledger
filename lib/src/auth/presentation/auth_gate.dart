import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../providers/auth_providers.dart';
import '../providers/app_settings_providers.dart';
import '../../routing/app_shell.dart';
import '../../migration/data/migration_service.dart';
import '../../migration/presentation/migration_screen.dart';
import '../../tutorial/onboarding_checklist_screen.dart';
import '../../theme/theme_provider.dart';
import '../../config/backend_contract.dart';
import 'auth_entry_screen.dart';
import 'maintenance_screen.dart';
import 'new_password_screen.dart';
import 'profile_setup_screen.dart';

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
    final adminAsync = ref.watch(currentUserIsAdminProvider);
    final backendContractAsync = ref.watch(backendContractProvider);

    return authState.when(
      data: (state) {
        if (state.event == AuthChangeEvent.passwordRecovery) {
          return const NewPasswordScreen();
        }
        if (state.session != null) {
          if (backendContractAsync.isLoading) {
            return const Scaffold(
              body: Center(child: CircularProgressIndicator()),
            );
          }
          if (backendContractAsync.hasError) {
            return _BackendContractScreen(
              compatibilityError:
                  backendContractAsync.error is BackendCompatibilityException,
              onRetry: () => ref.invalidate(backendContractProvider),
            );
          }

          // Reload theme settings when user logs in
          ref.read(themeModeProvider.notifier).reload();

          // Check maintenance mode - only admins can access
          final maintenanceEnabled = maintenanceAsync.valueOrNull ?? false;
          if (maintenanceEnabled) {
            if (adminAsync.isLoading) {
              return const Scaffold(
                body: Center(child: CircularProgressIndicator()),
              );
            }
            if (adminAsync.valueOrNull != true) {
              return const MaintenanceScreen();
            }
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

          final profileReady = ref.watch(profileReadyProvider);
          if (profileReady.isLoading) {
            return const Scaffold(
              body: Center(child: CircularProgressIndicator()),
            );
          }
          if (profileReady.hasError || profileReady.value != true) {
            return const ProfileSetupScreen();
          }

          // Check if tutorial is needed for new users
          final tutorialAsync = ref.watch(tutorialCompletedProvider);
          return tutorialAsync.when(
            data: (completed) {
              if (!completed) {
                return const OnboardingChecklistScreen();
              }
              return const AppShell();
            },
            loading: () => const Scaffold(
              body: Center(child: CircularProgressIndicator()),
            ),
            error: (_, __) => const AppShell(), // Skip tutorial on error
          );
        }
        return const AuthEntryScreen();
      },
      loading: () =>
          const Scaffold(body: Center(child: CircularProgressIndicator())),
      error: (_, __) => const Scaffold(
        body: Center(child: Text('Sign-in state could not be loaded.')),
      ),
    );
  }
}

class _BackendContractScreen extends StatelessWidget {
  final bool compatibilityError;
  final VoidCallback onRetry;

  const _BackendContractScreen({
    required this.compatibilityError,
    required this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 440),
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.sync_problem, size: 56),
                  const SizedBox(height: 16),
                  Text(
                    compatibilityError
                        ? 'Poker Ledger is being updated'
                        : 'Could not verify the backend',
                    style: Theme.of(context).textTheme.headlineSmall,
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 12),
                  Text(
                    compatibilityError
                        ? 'Your data is safe. Try again after the backend '
                              'update completes.'
                        : 'Check your connection and try again.',
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 20),
                  FilledButton.tonal(
                    onPressed: onRetry,
                    child: const Text('Try again'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
