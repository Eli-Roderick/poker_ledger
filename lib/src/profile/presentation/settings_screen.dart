import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../auth/providers/auth_providers.dart';
import '../../auth/providers/app_settings_providers.dart';
import '../../theme/theme_provider.dart';
import '../../tutorial/onboarding_checklist_screen.dart';
import '../../utils/idempotency_key.dart';

/// Provider for user settings from the profiles table
final userSettingsProvider = FutureProvider<UserSettings>((ref) async {
  final user = ref.watch(currentUserProvider);
  if (user == null) {
    return const UserSettings(
      discoverable: false,
      themeMode: 'system',
      tutorialCompleted: false,
    );
  }

  final data = await Supabase.instance.client
      .from('profiles')
      .select('discoverable, theme_mode, tutorial_completed')
      .eq('id', user.id)
      .maybeSingle();

  return UserSettings(
    discoverable: data?['discoverable'] as bool? ?? false,
    themeMode: data?['theme_mode'] as String? ?? 'system',
    tutorialCompleted: data?['tutorial_completed'] as bool? ?? false,
  );
});

/// User settings model
class UserSettings {
  final bool discoverable;
  final String themeMode;
  final bool tutorialCompleted;

  const UserSettings({
    required this.discoverable,
    required this.themeMode,
    required this.tutorialCompleted,
  });
}

/// Settings screen with theme, privacy, and account management options
class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  @override
  Widget build(BuildContext context) {
    final settingsAsync = ref.watch(userSettingsProvider);
    final adminAsync = ref.watch(currentUserIsAdminProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: settingsAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (_, __) =>
            const Center(child: Text('Settings could not be loaded.')),
        data: (settings) => ListView(
          children: [
            // Theme Settings Section
            _buildSectionHeader(context, 'Appearance'),
            _buildThemeSetting(context, settings.themeMode),

            const Divider(height: 32),

            // Privacy Settings Section
            _buildSectionHeader(context, 'Privacy'),
            _buildPrivacySetting(context, settings.discoverable),

            const Divider(height: 32),

            // Tutorial Section
            _buildSectionHeader(context, 'Help'),
            ListTile(
              leading: const Icon(Icons.school_outlined),
              title: const Text('App Tutorial'),
              subtitle: Text(
                settings.tutorialCompleted
                    ? 'Completed - Tap to restart'
                    : 'Learn how to use the app',
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => _startTutorial(context),
            ),

            const Divider(height: 32),

            // Account Section
            _buildSectionHeader(context, 'Account'),
            ListTile(
              leading: const Icon(Icons.delete_outline, color: Colors.red),
              title: const Text(
                'Delete Account',
                style: TextStyle(color: Colors.red),
              ),
              subtitle: const Text('Your data will be retained for 30 days'),
              onTap: () => _showDeleteAccountDialog(context),
            ),

            // Admin Section - only visible to admins, at the bottom
            if (adminAsync.valueOrNull == true) ...[
              const Divider(height: 32),
              _buildSectionHeader(context, 'Admin'),
              _buildAdminSettings(context, ref),
            ],

            const SizedBox(height: 32),
          ],
        ),
      ),
    );
  }

  Widget _buildSectionHeader(BuildContext context, String title) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      child: Text(
        title,
        style: Theme.of(context).textTheme.titleSmall?.copyWith(
          color: Theme.of(context).colorScheme.primary,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }

  Widget _buildThemeSetting(BuildContext context, String currentTheme) {
    return ListTile(
      leading: const Icon(Icons.palette_outlined),
      title: const Text('Theme'),
      subtitle: Text(_getThemeLabel(currentTheme)),
      trailing: const Icon(Icons.chevron_right),
      onTap: () => _showThemeDialog(context, currentTheme),
    );
  }

  String _getThemeLabel(String theme) {
    switch (theme) {
      case 'light':
        return 'Light';
      case 'dark':
        return 'Dark';
      default:
        return 'System default';
    }
  }

  Future<void> _showThemeDialog(
    BuildContext context,
    String currentTheme,
  ) async {
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Choose Theme'),
        content: RadioGroup<String>(
          groupValue: currentTheme,
          onChanged: (value) {
            if (value != null) {
              Navigator.pop(context, value);
            }
          },
          child: const Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              RadioListTile<String>(
                title: Text('System default'),
                subtitle: Text('Follow device settings'),
                value: 'system',
              ),
              RadioListTile<String>(title: Text('Light'), value: 'light'),
              RadioListTile<String>(title: Text('Dark'), value: 'dark'),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
        ],
      ),
    );

    if (result != null && result != currentTheme) {
      // Update theme provider which also persists to database
      await ref.read(themeModeProvider.notifier).setThemeMode(result);
      ref.invalidate(userSettingsProvider);
    }
  }

  Widget _buildPrivacySetting(BuildContext context, bool discoverable) {
    return SwitchListTile(
      secondary: const Icon(Icons.visibility_outlined),
      title: const Text('Discoverable profile'),
      subtitle: Text(
        discoverable
            ? 'People can find your handle or display name when inviting you'
            : 'People need your join code or an existing group connection',
      ),
      value: discoverable,
      onChanged: (value) => _updateSetting('discoverable', value),
    );
  }

  Widget _buildAdminSettings(BuildContext context, WidgetRef ref) {
    final maintenanceAsync = ref.watch(maintenanceModeProvider);

    return maintenanceAsync.when(
      loading: () => const ListTile(
        leading: Icon(Icons.admin_panel_settings),
        title: Text('Maintenance Mode'),
        trailing: SizedBox(
          width: 24,
          height: 24,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      ),
      error: (_, __) => const ListTile(
        leading: Icon(Icons.admin_panel_settings),
        title: Text('Maintenance Mode'),
        subtitle: Text('Maintenance status could not be loaded.'),
      ),
      data: (enabled) => SwitchListTile(
        secondary: const Icon(Icons.admin_panel_settings),
        title: const Text('Maintenance Mode'),
        subtitle: Text(
          enabled
              ? 'Only admins can access the app'
              : 'All users can access the app',
        ),
        value: enabled,
        onChanged: (value) {
          ref.read(maintenanceModeProvider.notifier).toggle();
        },
      ),
    );
  }

  Future<void> _updateSetting(String key, dynamic value) async {
    try {
      final user = Supabase.instance.client.auth.currentUser;
      if (user == null) return;

      await Supabase.instance.client
          .from('profiles')
          .update({key: value})
          .eq('id', user.id);

      ref.invalidate(userSettingsProvider);

      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Settings updated')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('The setting could not be saved.')),
        );
      }
    }
  }

  void _startTutorial(BuildContext context) {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const OnboardingChecklistScreen()),
    );
  }

  Future<void> _showDeleteAccountDialog(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete Account?'),
        content: const Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Are you sure you want to delete your account?'),
            SizedBox(height: 16),
            Text(
              'Your data will be retained for 30 days. If you sign in again '
              'with the same email during this period, you can restore your account.',
              style: TextStyle(fontSize: 14, color: Colors.grey),
            ),
            SizedBox(height: 8),
            Text(
              'You must explicitly transfer every group you own first. '
              'Open games use their assigned backup host or group authority; '
              'open private games become read-only.',
              style: TextStyle(fontSize: 14, color: Colors.grey),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            child: const Text('Delete Account'),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      await _deleteAccount();
    }
  }

  Future<void> _deleteAccount() async {
    try {
      final user = Supabase.instance.client.auth.currentUser;
      if (user == null) return;

      await Supabase.instance.client.rpc(
        'request_account_deletion',
        params: {'p_idempotency_key': IdempotencyKey.generate()},
      );

      // Sign out the user - this will trigger navigation to login screen
      await ref.read(authRepositoryProvider).signOut();

      // Pop all screens back to root (login screen will be shown due to auth state change)
      if (mounted) {
        Navigator.of(context).popUntil((route) => route.isFirst);
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Account deletion could not be scheduled. Transfer every '
              'group you own, then try again.',
            ),
          ),
        );
      }
    }
  }
}
