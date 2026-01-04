import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../features/analytics/presentation/analytics_screen.dart';
import '../features/analytics/data/analytics_providers.dart';
import '../features/groups/presentation/groups_screen.dart';
import '../features/players/presentation/players_list_screen.dart';
import '../features/session/presentation/sessions_home_screen.dart';
import '../features/session/data/sessions_list_providers.dart';
import '../profile/presentation/profile_screen.dart';

/// Main app shell with bottom navigation.
/// 
/// Contains the five main screens of the app:
/// - **Players**: Manage your player list (friends you play with)
/// - **Games**: Create and manage poker sessions
/// - **Stats**: View analytics, leaderboards, and session history
/// - **Groups**: Create and manage groups for sharing sessions
/// - **Profile**: Account settings and personal stats
/// 
/// The shell uses IndexedStack to keep all screens in memory for fast switching.
/// When switching to Stats or Games tabs, data is automatically refreshed.
class AppShell extends ConsumerStatefulWidget {
  const AppShell({super.key});

  @override
  ConsumerState<AppShell> createState() => _AppShellState();
}

class _AppShellState extends ConsumerState<AppShell> {
  int _index = 0;
  bool _showedOnboarding = false;

  final _screens = const [
    PlayersListScreen(),
    SessionsHomeScreen(),
    AnalyticsScreen(),
    GroupsScreen(),
    ProfileScreen(),
  ];

  @override
  void initState() {
    super.initState();
    _checkOnboarding();
  }

  Future<void> _checkOnboarding() async {
    final prefs = await SharedPreferences.getInstance();
    final seen = prefs.getBool('onboarding_seen') ?? false;
    if (!seen && mounted) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _showOnboardingDialog();
      });
    }
  }

  Future<void> _showOnboardingDialog() async {
    if (_showedOnboarding) return;
    _showedOnboarding = true;
    
    await showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => const _OnboardingDialog(),
    );
    
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('onboarding_seen', true);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      resizeToAvoidBottomInset: !kIsWeb,
      backgroundColor: const Color(0xFF111315),
      body: IndexedStack(
        index: _index,
        children: _screens,
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (i) {
          // Refresh data when switching to certain tabs
          if (i == 2 && _index != 2) {
            // Switching to Stats tab - refresh analytics
            ref.read(analyticsProvider.notifier).refresh();
          } else if (i == 1 && _index != 1) {
            // Switching to Games tab - refresh sessions list
            ref.read(sessionsListProvider.notifier).refresh();
          }
          setState(() => _index = i);
        },
        destinations: const [
          NavigationDestination(icon: Icon(Icons.people_outline), selectedIcon: Icon(Icons.people), label: 'Players'),
          NavigationDestination(icon: Icon(Icons.casino_outlined), selectedIcon: Icon(Icons.casino), label: 'Games'),
          NavigationDestination(icon: Icon(Icons.bar_chart_outlined), selectedIcon: Icon(Icons.bar_chart), label: 'Stats'),
          NavigationDestination(icon: Icon(Icons.group_outlined), selectedIcon: Icon(Icons.group), label: 'Groups'),
          NavigationDestination(icon: Icon(Icons.person_outline), selectedIcon: Icon(Icons.person), label: 'Profile'),
        ],
      ),
    );
  }
}

class _OnboardingDialog extends StatefulWidget {
  const _OnboardingDialog();

  @override
  State<_OnboardingDialog> createState() => _OnboardingDialogState();
}

class _OnboardingDialogState extends State<_OnboardingDialog> {
  int _page = 0;

  final _pages = const [
    _OnboardingPage(
      icon: Icons.casino,
      title: 'Welcome to Poker Ledger!',
      description: 'Track your poker games, see who owes who, and keep stats on your wins and losses.',
    ),
    _OnboardingPage(
      icon: Icons.people,
      title: 'Add Your Players',
      description: 'First, add the people you play with. Search by name or email to link their accounts so stats sync automatically.',
    ),
    _OnboardingPage(
      icon: Icons.play_arrow,
      title: 'Start a Game',
      description: 'Create a new game, add players with their buy-ins, then enter cash outs when done.',
    ),
    _OnboardingPage(
      icon: Icons.attach_money,
      title: 'Settle Up',
      description: 'The app calculates who owes who. Finalize the game to lock it and track your stats!',
    ),
  ];

  @override
  Widget build(BuildContext context) {
    final isLast = _page == _pages.length - 1;
    
    return AlertDialog(
      contentPadding: const EdgeInsets.all(24),
      content: SizedBox(
        width: 300,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _pages[_page],
            const SizedBox(height: 24),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: List.generate(_pages.length, (i) => Container(
                width: 8,
                height: 8,
                margin: const EdgeInsets.symmetric(horizontal: 4),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: i == _page 
                      ? Theme.of(context).colorScheme.primary 
                      : Colors.grey.shade300,
                ),
              )),
            ),
          ],
        ),
      ),
      actions: [
        if (_page > 0)
          TextButton(
            onPressed: () => setState(() => _page--),
            child: const Text('Back'),
          ),
        FilledButton(
          onPressed: () {
            if (isLast) {
              Navigator.pop(context);
            } else {
              setState(() => _page++);
            }
          },
          child: Text(isLast ? 'Get Started' : 'Next'),
        ),
      ],
    );
  }
}

class _OnboardingPage extends StatelessWidget {
  final IconData icon;
  final String title;
  final String description;

  const _OnboardingPage({
    required this.icon,
    required this.title,
    required this.description,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 64, color: Theme.of(context).colorScheme.primary),
        const SizedBox(height: 16),
        Text(
          title,
          style: Theme.of(context).textTheme.titleLarge?.copyWith(
            fontWeight: FontWeight.bold,
          ),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 12),
        Text(
          description,
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
            color: Colors.grey.shade600,
          ),
          textAlign: TextAlign.center,
        ),
      ],
    );
  }
}
