import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../features/analytics/presentation/analytics_screen.dart';
import '../features/analytics/data/analytics_providers.dart';
import '../features/groups/data/group_providers.dart';
import '../features/home/presentation/home_screen.dart';
import '../features/groups/presentation/groups_screen.dart';
import '../features/session/presentation/join_accepted_buy_in_dialog.dart';
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

class _AppShellState extends ConsumerState<AppShell>
    with WidgetsBindingObserver {
  int _index = 0;
  RealtimeChannel? _userChannel;
  Timer? _invalidateDebounce;
  bool _acceptanceDialogOpen = false;

  late final List<Widget> _screens;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
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
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final launchUri = Uri.base;
      if (joinCodeFromDeepLink(launchUri) != null &&
          ref.read(pendingDeepLinkProvider) == null) {
        ref.read(pendingDeepLinkProvider.notifier).state = launchUri;
      }
      _openPendingDeepLink();
      _subscribeToUserRealtime();
      _openExistingPendingBuyIn();
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _invalidateDebounce?.cancel();
    final channel = _userChannel;
    _userChannel = null;
    if (channel != null) {
      Supabase.instance.client.removeChannel(channel);
    }
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _softRefreshVisibleProviders();
    }
  }

  void _softRefreshVisibleProviders() {
    ref.invalidate(pendingGameInvitationsProvider);
    ref.invalidate(pendingGroupInvitationsProvider);
    ref.invalidate(unreadNotificationsProvider);
    ref.invalidate(openSettlementTransfersProvider);
  }

  void _scheduleHomeInvalidation() {
    _invalidateDebounce?.cancel();
    _invalidateDebounce = Timer(const Duration(milliseconds: 200), () {
      if (!mounted) return;
      ref.invalidate(pendingGameInvitationsProvider);
      ref.invalidate(pendingGroupInvitationsProvider);
      ref.invalidate(unreadNotificationsProvider);
      ref.invalidate(openSettlementTransfersProvider);
    });
  }

  void _subscribeToUserRealtime() {
    final userId = Supabase.instance.client.auth.currentUser?.id;
    if (userId == null) return;
    final client = Supabase.instance.client;
    _userChannel = client
        .channel('app-user-sync-$userId')
        .onPostgresChanges(
          event: PostgresChangeEvent.insert,
          schema: 'public',
          table: 'game_invitations',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'profile_id',
            value: userId,
          ),
          callback: (_) => _scheduleHomeInvalidation(),
        )
        .onPostgresChanges(
          event: PostgresChangeEvent.update,
          schema: 'public',
          table: 'game_invitations',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'profile_id',
            value: userId,
          ),
          callback: (payload) {
            _scheduleHomeInvalidation();
            final row = payload.newRecord;
            final status = row['status'] as String?;
            final invitationId = row['id'] as String?;
            final sessionId = row['session_id'];
            if (status != 'accepted_pending_buy_in' || invitationId == null) {
              return;
            }
            final parsedSessionId = sessionId is int
                ? sessionId
                : int.tryParse('$sessionId');
            if (parsedSessionId == null) return;
            _handlePendingBuyInInvitation(
              invitationId: invitationId,
              sessionId: parsedSessionId,
            );
          },
        )
        .onPostgresChanges(
          event: PostgresChangeEvent.insert,
          schema: 'public',
          table: 'user_notifications',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'user_id',
            value: userId,
          ),
          callback: (_) => _scheduleHomeInvalidation(),
        )
        .onPostgresChanges(
          event: PostgresChangeEvent.update,
          schema: 'public',
          table: 'user_notifications',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'user_id',
            value: userId,
          ),
          callback: (_) => _scheduleHomeInvalidation(),
        )
        .onPostgresChanges(
          event: PostgresChangeEvent.insert,
          schema: 'public',
          table: 'group_invitations',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'profile_id',
            value: userId,
          ),
          callback: (_) => _scheduleHomeInvalidation(),
        )
        .onPostgresChanges(
          event: PostgresChangeEvent.update,
          schema: 'public',
          table: 'group_invitations',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'profile_id',
            value: userId,
          ),
          callback: (_) => _scheduleHomeInvalidation(),
        )
        .onPostgresChanges(
          event: PostgresChangeEvent.insert,
          schema: 'public',
          table: 'settlement_transfers',
          callback: (_) => _scheduleHomeInvalidation(),
        )
        .onPostgresChanges(
          event: PostgresChangeEvent.update,
          schema: 'public',
          table: 'settlement_transfers',
          callback: (_) => _scheduleHomeInvalidation(),
        )
        .subscribe();
  }

  Future<void> _openExistingPendingBuyIn() async {
    final userId = Supabase.instance.client.auth.currentUser?.id;
    if (userId == null || !mounted) return;
    try {
      final row = await Supabase.instance.client
          .from('game_invitations')
          .select('id, session_id')
          .eq('profile_id', userId)
          .eq('status', 'accepted_pending_buy_in')
          .order('created_at', ascending: false)
          .limit(1)
          .maybeSingle();
      if (row == null || !mounted) return;
      final invitationId = row['id'] as String?;
      final sessionIdRaw = row['session_id'];
      final sessionId = sessionIdRaw is int
          ? sessionIdRaw
          : int.tryParse('$sessionIdRaw');
      if (invitationId == null || sessionId == null) return;
      await _handlePendingBuyInInvitation(
        invitationId: invitationId,
        sessionId: sessionId,
      );
    } catch (_) {
      // Best-effort resume of unfinished buy-in confirmation.
    }
  }

  Future<void> _handlePendingBuyInInvitation({
    required String invitationId,
    required int sessionId,
  }) async {
    if (_acceptanceDialogOpen || !mounted) return;
    _acceptanceDialogOpen = true;
    try {
      await showJoinAcceptedBuyInDialog(
        context: context,
        ref: ref,
        sessionId: sessionId,
        invitationId: invitationId,
      );
      ref.read(sessionsListProvider.notifier).refresh();
    } finally {
      _acceptanceDialogOpen = false;
    }
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
    final pendingInviteCount =
        ref.watch(pendingGameInvitationsProvider).valueOrNull?.length ?? 0;
    final profileIcon = Badge(
      isLabelVisible: pendingInviteCount > 0,
      label: Text('$pendingInviteCount'),
      child: const Icon(Icons.person_outline),
    );
    final profileSelectedIcon = Badge(
      isLabelVisible: pendingInviteCount > 0,
      label: Text('$pendingInviteCount'),
      child: const Icon(Icons.person),
    );
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
                  destinations: [
                    const NavigationRailDestination(
                      icon: Icon(Icons.home_outlined),
                      selectedIcon: Icon(Icons.home),
                      label: Text('Home'),
                    ),
                    const NavigationRailDestination(
                      icon: Icon(Icons.casino_outlined),
                      selectedIcon: Icon(Icons.casino),
                      label: Text('Games'),
                    ),
                    const NavigationRailDestination(
                      icon: Icon(Icons.bar_chart_outlined),
                      selectedIcon: Icon(Icons.bar_chart),
                      label: Text('Stats'),
                    ),
                    const NavigationRailDestination(
                      icon: Icon(Icons.group_outlined),
                      selectedIcon: Icon(Icons.group),
                      label: Text('Groups'),
                    ),
                    NavigationRailDestination(
                      icon: profileIcon,
                      selectedIcon: profileSelectedIcon,
                      label: const Text('Profile'),
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
            destinations: [
              const NavigationDestination(
                icon: Icon(Icons.home_outlined),
                selectedIcon: Icon(Icons.home),
                label: 'Home',
              ),
              const NavigationDestination(
                icon: Icon(Icons.casino_outlined),
                selectedIcon: Icon(Icons.casino),
                label: 'Games',
              ),
              const NavigationDestination(
                icon: Icon(Icons.bar_chart_outlined),
                selectedIcon: Icon(Icons.bar_chart),
                label: 'Stats',
              ),
              const NavigationDestination(
                icon: Icon(Icons.group_outlined),
                selectedIcon: Icon(Icons.group),
                label: 'Groups',
              ),
              NavigationDestination(
                icon: profileIcon,
                selectedIcon: profileSelectedIcon,
                label: 'Profile',
              ),
            ],
          ),
        );
      },
    );
  }

  void _selectDestination(int index) {
    if (index == 0 && _index != 0) {
      _softRefreshVisibleProviders();
      ref.read(sessionsListProvider.notifier).refresh();
    } else if (index == 2 && _index != 2) {
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
        final sessionIdRaw = result['session_id'];
        final sessionId = sessionIdRaw is int
            ? sessionIdRaw
            : int.tryParse('$sessionIdRaw');
        final invitationId = result['invitation_id'] as String?;
        final message = switch (status) {
          'pending_host' => 'Join request sent to the host.',
          'pending_invitee' => 'You already have an invitation to this game.',
          'accepted_pending_buy_in' => 'Confirm your buy-in to join.',
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
        if (status == 'accepted_pending_buy_in' &&
            sessionId != null &&
            invitationId != null) {
          await _handlePendingBuyInInvitation(
            invitationId: invitationId,
            sessionId: sessionId,
          );
        } else if ((status == 'participating' || status == 'accepted') &&
            sessionId != null) {
          await Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => V2GameFlowScreen(sessionId: sessionId),
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
