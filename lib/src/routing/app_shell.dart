import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../features/analytics/presentation/analytics_screen.dart';
import '../features/analytics/data/analytics_providers.dart';
import '../features/home/presentation/home_screen.dart';
import '../features/groups/presentation/groups_screen.dart';
import '../features/session/presentation/sessions_home_screen.dart';
import '../features/session/data/sessions_list_providers.dart';
import '../features/session/data/v2_game_providers.dart';
import '../features/session/presentation/v2_game_flow_screen.dart';
import '../profile/presentation/profile_screen.dart';
import 'pending_deep_link.dart';

/// Main app shell with bottom navigation.
///
/// Contains the five main screens of the app:
/// - **Home**: Continue active work and review pending actions
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

  late final List<Widget> _screens;

  @override
  void initState() {
    super.initState();
    _screens = [
      HomeScreen(
        onOpenGames: () => setState(() => _index = 1),
        onOpenGroups: () => setState(() => _index = 3),
      ),
      const SessionsHomeScreen(),
      const AnalyticsScreen(),
      const GroupsScreen(),
      const ProfileScreen(),
    ];
    WidgetsBinding.instance.addPostFrameCallback((_) => _openPendingDeepLink());
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<Uri?>(pendingDeepLinkProvider, (previous, next) {
      if (next != null && next != previous) {
        WidgetsBinding.instance.addPostFrameCallback(
          (_) => _openPendingDeepLink(),
        );
      }
    });
    final body = buildTabStack(selectedIndex: _index, screens: _screens);
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth >= 800) {
          return Scaffold(
            resizeToAvoidBottomInset: true,
            body: Row(
              children: [
                NavigationRail(
                  selectedIndex: _index,
                  onDestinationSelected: _selectDestination,
                  labelType: NavigationRailLabelType.all,
                  destinations: const [
                    NavigationRailDestination(
                      icon: Icon(Icons.home_outlined),
                      selectedIcon: Icon(Icons.home),
                      label: Text('Home'),
                    ),
                    NavigationRailDestination(
                      icon: Icon(Icons.casino_outlined),
                      selectedIcon: Icon(Icons.casino),
                      label: Text('Games'),
                    ),
                    NavigationRailDestination(
                      icon: Icon(Icons.bar_chart_outlined),
                      selectedIcon: Icon(Icons.bar_chart),
                      label: Text('Stats'),
                    ),
                    NavigationRailDestination(
                      icon: Icon(Icons.group_outlined),
                      selectedIcon: Icon(Icons.group),
                      label: Text('Groups'),
                    ),
                    NavigationRailDestination(
                      icon: Icon(Icons.person_outline),
                      selectedIcon: Icon(Icons.person),
                      label: Text('Profile'),
                    ),
                  ],
                ),
                const VerticalDivider(width: 1),
                Expanded(child: body),
              ],
            ),
          );
        }
        return Scaffold(
          resizeToAvoidBottomInset: true,
          body: body,
          bottomNavigationBar: NavigationBar(
            selectedIndex: _index,
            onDestinationSelected: _selectDestination,
            destinations: const [
              NavigationDestination(
                icon: Icon(Icons.home_outlined),
                selectedIcon: Icon(Icons.home),
                label: 'Home',
              ),
              NavigationDestination(
                icon: Icon(Icons.casino_outlined),
                selectedIcon: Icon(Icons.casino),
                label: 'Games',
              ),
              NavigationDestination(
                icon: Icon(Icons.bar_chart_outlined),
                selectedIcon: Icon(Icons.bar_chart),
                label: 'Stats',
              ),
              NavigationDestination(
                icon: Icon(Icons.group_outlined),
                selectedIcon: Icon(Icons.group),
                label: 'Groups',
              ),
              NavigationDestination(
                icon: Icon(Icons.person_outline),
                selectedIcon: Icon(Icons.person),
                label: 'Profile',
              ),
            ],
          ),
        );
      },
    );
  }

  void _selectDestination(int index) {
    if (index == 2 && _index != 2) {
      ref.read(analyticsProvider.notifier).refresh();
    } else if (index == 1 && _index != 1) {
      ref.read(sessionsListProvider.notifier).refresh();
    }
    setState(() => _index = index);
  }

  Future<void> _openPendingDeepLink() async {
    final uri = ref.read(pendingDeepLinkProvider);
    if (uri == null || !mounted) return;
    final code = joinCodeFromDeepLink(uri);
    if (code != null) {
      try {
        final result = await ref
            .read(v2GameRepositoryProvider)
            .requestJoin(code);
        if (!mounted) return;
        final status = result['status'] as String?;
        final message = switch (status) {
          'pending_host' => 'Join request sent to the host.',
          'pending_invitee' => 'You already have an invitation to this game.',
          'participating' => 'You are already in this game.',
          'accepted' => 'You are already in this game.',
          _ =>
            result['message'] as String? ??
                'This game link is no longer available.',
        };
        setState(() => _index = 1);
        ref.read(pendingDeepLinkProvider.notifier).state = null;
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(message)));
        if ((status == 'participating' || status == 'accepted') &&
            result['session_id'] is int) {
          await Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) =>
                  V2GameFlowScreen(sessionId: result['session_id'] as int),
            ),
          );
        }
      } catch (_) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text(
                'The game link could not be opened. Check your connection '
                'and try again.',
              ),
            ),
          );
        }
      }
      return;
    }
    if (uri.host == 'group-invite' ||
        uri.pathSegments.contains('group-invite')) {
      setState(() => _index = 3);
    } else {
      setState(() => _index = 1);
    }
    ref.read(pendingDeepLinkProvider.notifier).state = null;
  }
}

Widget buildTabStack({
  required int selectedIndex,
  required List<Widget> screens,
}) {
  return IndexedStack(
    index: selectedIndex,
    children: [
      for (var childIndex = 0; childIndex < screens.length; childIndex++)
        HeroMode(
          enabled: childIndex == selectedIndex,
          child: screens[childIndex],
        ),
    ],
  );
}
