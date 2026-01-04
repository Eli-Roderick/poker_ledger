import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../routing/app_shell.dart';
import 'tutorial_overlay.dart';

/// Global keys for tutorial targets
class TutorialTargets {
  static final playersTab = GlobalKey();
  static final gamesTab = GlobalKey();
  static final statsTab = GlobalKey();
  static final groupsTab = GlobalKey();
  static final profileTab = GlobalKey();
}

/// Interactive tutorial that guides users through the app with spotlight effects
class InteractiveTutorial extends ConsumerStatefulWidget {
  const InteractiveTutorial({super.key});

  @override
  ConsumerState<InteractiveTutorial> createState() => _InteractiveTutorialState();
}

class _InteractiveTutorialState extends ConsumerState<InteractiveTutorial> {
  late TutorialController _controller;
  int _currentNavIndex = 0;
  bool _showingApp = false;
  
  @override
  void initState() {
    super.initState();
    _controller = TutorialController(steps: _buildSteps());
    
    // Start with welcome screen, then transition to app with tutorial
    Future.delayed(const Duration(milliseconds: 500), () {
      if (mounted) {
        setState(() => _showingApp = true);
        Future.delayed(const Duration(milliseconds: 300), () {
          _controller.start();
        });
      }
    });
  }
  
  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }
  
  List<TutorialStep> _buildSteps() {
    return [
      // Welcome step - no target, centered
      const TutorialStep(
        title: 'Welcome to Poker Ledger',
        description: 'Let\'s take a quick tour of the app to help you get started. '
            'This will only take a minute.',
        tooltipAlignment: Alignment.center,
        showSkip: true,
      ),
      
      // Players tab (index 0)
      TutorialStep(
        title: 'Players',
        description: 'Manage your players here. Add players by searching for their name or email, '
            'and their stats will sync across all your games together.',
        targetKey: TutorialTargets.playersTab,
        navigationIndex: 0,
        tooltipAlignment: Alignment.topCenter,
      ),
      
      // Games tab (index 1)
      TutorialStep(
        title: 'Games',
        description: 'This is where you\'ll track your poker games. '
            'Create a new game each time you play, add players, and record buy-ins and cash-outs.',
        targetKey: TutorialTargets.gamesTab,
        navigationIndex: 1,
        tooltipAlignment: Alignment.topCenter,
      ),
      
      // Stats tab (index 2)
      TutorialStep(
        title: 'Stats',
        description: 'View detailed analytics about your poker performance. '
            'See win rates, profit trends, and compare stats with other players.',
        targetKey: TutorialTargets.statsTab,
        navigationIndex: 2,
        tooltipAlignment: Alignment.topCenter,
      ),
      
      // Groups tab (index 3)
      TutorialStep(
        title: 'Groups',
        description: 'Create groups with your regular poker crew. '
            'Share games with the group to track everyone\'s performance together.',
        targetKey: TutorialTargets.groupsTab,
        navigationIndex: 3,
        tooltipAlignment: Alignment.topCenter,
      ),
      
      // Profile tab (index 4)
      TutorialStep(
        title: 'Profile',
        description: 'View your profile, manage settings, and customize your experience.',
        targetKey: TutorialTargets.profileTab,
        navigationIndex: 4,
        tooltipAlignment: Alignment.topCenter,
      ),
      
      // Final step
      const TutorialStep(
        title: 'You\'re All Set',
        description: 'That\'s the basics. Start by adding some players, then create your first game. '
            'You can always access help from the settings.',
        tooltipAlignment: Alignment.center,
        navigationIndex: 0,
        showSkip: false,
      ),
    ];
  }
  
  void _onNavigationRequested(int index) {
    setState(() => _currentNavIndex = index);
  }
  
  Future<void> _onTutorialComplete() async {
    // Mark tutorial as completed in database
    try {
      final user = Supabase.instance.client.auth.currentUser;
      if (user != null) {
        await Supabase.instance.client
            .from('profiles')
            .update({'tutorial_completed': true})
            .eq('id', user.id);
      }
    } catch (e) {
      // Ignore errors - tutorial completion is not critical
    }
    
    // Navigate to the main app
    if (mounted) {
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => const AppShell()),
      );
    }
  }
  
  @override
  Widget build(BuildContext context) {
    if (!_showingApp) {
      // Show loading/welcome animation
      return Scaffold(
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                Icons.casino,
                size: 80,
                color: Theme.of(context).colorScheme.primary,
              ),
              const SizedBox(height: 24),
              Text(
                'Poker Ledger',
                style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 16),
              const CircularProgressIndicator(),
            ],
          ),
        ),
      );
    }
    
    return TutorialOverlay(
      controller: _controller,
      onComplete: _onTutorialComplete,
      onNavigationRequested: _onNavigationRequested,
      child: _TutorialAppShell(
        currentIndex: _currentNavIndex,
        onIndexChanged: (index) => setState(() => _currentNavIndex = index),
      ),
    );
  }
}

/// A simplified app shell for the tutorial that exposes the navigation keys
class _TutorialAppShell extends StatelessWidget {
  final int currentIndex;
  final ValueChanged<int> onIndexChanged;
  
  const _TutorialAppShell({
    required this.currentIndex,
    required this.onIndexChanged,
  });
  
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: _buildBody(context),
      bottomNavigationBar: NavigationBar(
        selectedIndex: currentIndex,
        onDestinationSelected: onIndexChanged,
        destinations: [
          NavigationDestination(
            key: TutorialTargets.playersTab,
            icon: const Icon(Icons.people_outline),
            selectedIcon: const Icon(Icons.people),
            label: 'Players',
          ),
          NavigationDestination(
            key: TutorialTargets.gamesTab,
            icon: const Icon(Icons.casino_outlined),
            selectedIcon: const Icon(Icons.casino),
            label: 'Games',
          ),
          NavigationDestination(
            key: TutorialTargets.statsTab,
            icon: const Icon(Icons.bar_chart_outlined),
            selectedIcon: const Icon(Icons.bar_chart),
            label: 'Stats',
          ),
          NavigationDestination(
            key: TutorialTargets.groupsTab,
            icon: const Icon(Icons.group_outlined),
            selectedIcon: const Icon(Icons.group),
            label: 'Groups',
          ),
          NavigationDestination(
            key: TutorialTargets.profileTab,
            icon: const Icon(Icons.person_outline),
            selectedIcon: const Icon(Icons.person),
            label: 'Profile',
          ),
        ],
      ),
    );
  }
  
  Widget _buildBody(BuildContext context) {
    // Show placeholder content for each tab during tutorial
    final titles = ['Players', 'Games', 'Stats', 'Groups', 'Profile'];
    final icons = [
      Icons.people,
      Icons.casino,
      Icons.bar_chart,
      Icons.group,
      Icons.person,
    ];
    final descriptions = [
      'Add and manage your players',
      'Track your poker games and manage buy-ins',
      'View your performance analytics',
      'Create groups to share games',
      'Manage your profile and settings',
    ];
    
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              icons[currentIndex],
              size: 64,
              color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.5),
            ),
            const SizedBox(height: 16),
            Text(
              titles[currentIndex],
              style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.7),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              descriptions[currentIndex],
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.5),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
