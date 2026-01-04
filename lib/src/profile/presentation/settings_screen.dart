import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../auth/providers/auth_providers.dart';
import '../../auth/providers/app_settings_providers.dart';
import '../../auth/data/admin_config.dart';
import '../../theme/theme_provider.dart';
import '../../tutorial/interactive_tutorial.dart';

/// Provider for user settings from the profiles table
final userSettingsProvider = FutureProvider<UserSettings>((ref) async {
  final user = ref.watch(currentUserProvider);
  if (user == null) {
    return const UserSettings(
      isPublic: false,
      themeMode: 'system',
      tutorialCompleted: false,
    );
  }
  
  final data = await Supabase.instance.client
      .from('profiles')
      .select('is_public, theme_mode, tutorial_completed')
      .eq('id', user.id)
      .maybeSingle();
  
  return UserSettings(
    isPublic: data?['is_public'] as bool? ?? false,
    themeMode: data?['theme_mode'] as String? ?? 'system',
    tutorialCompleted: data?['tutorial_completed'] as bool? ?? false,
  );
});

/// User settings model
class UserSettings {
  final bool isPublic;
  final String themeMode;
  final bool tutorialCompleted;
  
  const UserSettings({
    required this.isPublic,
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
    final user = Supabase.instance.client.auth.currentUser;
    final settingsAsync = ref.watch(userSettingsProvider);
    
    return Scaffold(
      appBar: AppBar(
        title: const Text('Settings'),
      ),
      body: settingsAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Error: $e')),
        data: (settings) => ListView(
          children: [
            // Theme Settings Section
            _buildSectionHeader(context, 'Appearance'),
            _buildThemeSetting(context, settings.themeMode),
            
            const Divider(height: 32),
            
            // Privacy Settings Section
            _buildSectionHeader(context, 'Privacy'),
            _buildPrivacySetting(context, settings.isPublic),
            
            const Divider(height: 32),
            
            // Tutorial Section
            _buildSectionHeader(context, 'Help'),
            ListTile(
              leading: const Icon(Icons.school_outlined),
              title: const Text('App Tutorial'),
              subtitle: Text(settings.tutorialCompleted 
                  ? 'Completed - Tap to restart' 
                  : 'Learn how to use the app'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => _startTutorial(context),
            ),
            
            const Divider(height: 32),
            
            // Account Section
            _buildSectionHeader(context, 'Account'),
            ListTile(
              leading: const Icon(Icons.delete_outline, color: Colors.red),
              title: const Text('Delete Account', 
                  style: TextStyle(color: Colors.red)),
              subtitle: const Text('Your data will be retained for 30 days'),
              onTap: () => _showDeleteAccountDialog(context),
            ),
            
            // Admin Section - only visible to admins, at the bottom
            if (AdminConfig.isAdmin(user?.id)) ...[
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
  
  Future<void> _showThemeDialog(BuildContext context, String currentTheme) async {
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Choose Theme'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            RadioListTile<String>(
              title: const Text('System default'),
              subtitle: const Text('Follow device settings'),
              value: 'system',
              groupValue: currentTheme,
              onChanged: (v) => Navigator.pop(context, v),
            ),
            RadioListTile<String>(
              title: const Text('Light'),
              value: 'light',
              groupValue: currentTheme,
              onChanged: (v) => Navigator.pop(context, v),
            ),
            RadioListTile<String>(
              title: const Text('Dark'),
              value: 'dark',
              groupValue: currentTheme,
              onChanged: (v) => Navigator.pop(context, v),
            ),
          ],
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
  
  Widget _buildPrivacySetting(BuildContext context, bool isPublic) {
    return SwitchListTile(
      secondary: const Icon(Icons.visibility_outlined),
      title: const Text('Public Profile'),
      subtitle: Text(isPublic 
          ? 'Anyone can follow you without approval' 
          : 'Follow requests require your approval'),
      value: isPublic,
      onChanged: (value) => _updateSetting('is_public', value),
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
      error: (e, _) => ListTile(
        leading: const Icon(Icons.admin_panel_settings),
        title: const Text('Maintenance Mode'),
        subtitle: Text('Error: $e'),
      ),
      data: (enabled) => SwitchListTile(
        secondary: const Icon(Icons.admin_panel_settings),
        title: const Text('Maintenance Mode'),
        subtitle: Text(enabled 
            ? 'Only admins can access the app' 
            : 'All users can access the app'),
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
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Settings updated')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e')),
        );
      }
    }
  }
  
  void _startTutorial(BuildContext context) {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const InteractiveTutorial()),
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
              'Groups you own will be transferred to the oldest member, or deleted if empty.',
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
      
      // Schedule deletion for 30 days from now
      final deletionDate = DateTime.now().add(const Duration(days: 30));
      
      await Supabase.instance.client
          .from('profiles')
          .update({
            'deleted_at': DateTime.now().toIso8601String(),
            'deletion_scheduled_at': deletionDate.toIso8601String(),
          })
          .eq('id', user.id);
      
      // Sign out the user - this will trigger navigation to login screen
      await ref.read(authRepositoryProvider).signOut();
      
      // Pop all screens back to root (login screen will be shown due to auth state change)
      if (mounted) {
        Navigator.of(context).popUntil((route) => route.isFirst);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e')),
        );
      }
    }
  }
}

/// Tutorial screen for new users
class TutorialScreen extends ConsumerStatefulWidget {
  const TutorialScreen({super.key});

  @override
  ConsumerState<TutorialScreen> createState() => _TutorialScreenState();
}

class _TutorialScreenState extends ConsumerState<TutorialScreen> {
  int _currentStep = 0;
  
  final List<TutorialStep> _steps = [
    TutorialStep(
      title: 'Welcome to Poker Ledger!',
      description: 'Track your poker sessions, manage players, and analyze your performance. '
          'Let\'s walk through the main features.',
      icon: Icons.casino,
      color: Colors.purple,
    ),
    TutorialStep(
      title: 'Players',
      description: 'Start by adding players - these are the people you play poker with. '
          'You can link players to registered accounts to share stats across users.',
      icon: Icons.people,
      color: Colors.blue,
    ),
    TutorialStep(
      title: 'Sessions',
      description: 'Create a session for each poker game. Add players, track buy-ins and rebuys, '
          'then enter cash-outs when the game ends. The app calculates who owes whom.',
      icon: Icons.style,
      color: Colors.green,
    ),
    TutorialStep(
      title: 'Stats',
      description: 'View your performance analytics - total profit/loss, win rate, '
          'and leaderboards. Filter by date range or group to see specific stats.',
      icon: Icons.bar_chart,
      color: Colors.orange,
    ),
    TutorialStep(
      title: 'Groups',
      description: 'Create groups to share sessions with friends. When you share a session '
          'to a group, all members can see it in their stats.',
      icon: Icons.group_work,
      color: Colors.teal,
    ),
    TutorialStep(
      title: 'Following',
      description: 'Follow other users to see their complete poker history. '
          'If your profile is private, others need your approval to follow you.',
      icon: Icons.person_add,
      color: Colors.indigo,
    ),
    TutorialStep(
      title: 'You\'re Ready!',
      description: 'That\'s the basics! Start by adding some players, then create your first session. '
          'Tap the help icon (?) on any screen for more details.',
      icon: Icons.check_circle,
      color: Colors.green,
    ),
  ];
  
  @override
  Widget build(BuildContext context) {
    final step = _steps[_currentStep];
    final isLastStep = _currentStep == _steps.length - 1;
    
    return Scaffold(
      backgroundColor: step.color.withOpacity(0.1),
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.close),
          onPressed: () => Navigator.pop(context),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Skip'),
          ),
        ],
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            children: [
              // Progress indicator
              Row(
                children: List.generate(_steps.length, (i) => Expanded(
                  child: Container(
                    height: 4,
                    margin: const EdgeInsets.symmetric(horizontal: 2),
                    decoration: BoxDecoration(
                      color: i <= _currentStep 
                          ? step.color 
                          : step.color.withOpacity(0.3),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                )),
              ),
              
              const Spacer(),
              
              // Icon
              Container(
                width: 120,
                height: 120,
                decoration: BoxDecoration(
                  color: step.color.withOpacity(0.2),
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  step.icon,
                  size: 60,
                  color: step.color,
                ),
              ),
              
              const SizedBox(height: 32),
              
              // Title
              Text(
                step.title,
                style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
                textAlign: TextAlign.center,
              ),
              
              const SizedBox(height: 16),
              
              // Description
              Text(
                step.description,
                style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                  color: Colors.grey[600],
                ),
                textAlign: TextAlign.center,
              ),
              
              const Spacer(),
              
              // Navigation buttons
              Row(
                children: [
                  if (_currentStep > 0)
                    Expanded(
                      child: OutlinedButton(
                        onPressed: () => setState(() => _currentStep--),
                        child: const Text('Back'),
                      ),
                    ),
                  if (_currentStep > 0) const SizedBox(width: 16),
                  Expanded(
                    child: FilledButton(
                      onPressed: () {
                        if (isLastStep) {
                          _completeTutorial();
                        } else {
                          setState(() => _currentStep++);
                        }
                      },
                      style: FilledButton.styleFrom(
                        backgroundColor: step.color,
                      ),
                      child: Text(isLastStep ? 'Get Started' : 'Next'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
  
  Future<void> _completeTutorial() async {
    try {
      final user = Supabase.instance.client.auth.currentUser;
      if (user != null) {
        await Supabase.instance.client
            .from('profiles')
            .update({'tutorial_completed': true})
            .eq('id', user.id);
      }
      
      // Invalidate providers to trigger navigation to app
      ref.invalidate(userSettingsProvider);
    } catch (e) {
      // Ignore errors - tutorial completion is not critical
    }
    
    // If shown from auth_gate (no navigator to pop), just let the provider refresh handle it
    // If shown from settings, pop back
    if (mounted && Navigator.of(context).canPop()) {
      Navigator.pop(context);
    }
  }
}

/// Model for a tutorial step
class TutorialStep {
  final String title;
  final String description;
  final IconData icon;
  final Color color;
  
  const TutorialStep({
    required this.title,
    required this.description,
    required this.icon,
    required this.color,
  });
}
