import 'package:supabase_flutter/supabase_flutter.dart';
import '../../session/data/session_repository.dart';
import '../domain/profile_models.dart';

/// Repository for user profile operations.
///
/// Handles profiles and participation/group-scoped statistics.
class ProfileRepository {
  final SupabaseClient _client = Supabase.instance.client;

  /// The currently authenticated user's ID
  String get _currentUserId => _client.auth.currentUser!.id;

  /// Get user profile info by user ID
  Future<Map<String, dynamic>?> getUserProfile(String oderId) async {
    final data = await _client
        .from('profiles')
        .select('id, display_name, handle')
        .eq('id', oderId)
        .maybeSingle();
    return data;
  }

  /// Get stats for a user from sessions accessible to the current user
  /// This includes:
  Future<UserProfileStats> getUserStats(
    String targetUserId, {
    int? groupId,
  }) async {
    // Get accessible session IDs for this user
    final accessibleSessionIds = await _getAccessibleSessionIds(
      targetUserId,
      groupId: groupId,
    );

    if (accessibleSessionIds.isEmpty) {
      final profile = await getUserProfile(targetUserId);
      return UserProfileStats(
        userId: targetUserId,
        displayName: profile?['display_name'] as String?,
        email: null,
        totalSessions: 0,
        totalBuyInsCents: 0,
        totalCashOutsCents: 0,
        netProfitCents: 0,
        winRate: 0,
        biggestWinCents: 0,
        biggestLossCents: 0,
      );
    }

    final sessionPlayersData =
        (await SessionRepository().listSessionPlayersForMultipleSessions(
          accessibleSessionIds,
        )).where((row) => row['linked_user_id'] == targetUserId).toList();

    int totalSessions = 0;
    int totalBuyIns = 0;
    int totalCashOuts = 0;
    int wins = 0;
    int biggestWin = 0;
    int biggestLoss = 0;
    Set<int> sessionIds = {};

    for (final sp in sessionPlayersData) {
      final sessionId = sp['session_id'] as int;
      if (sessionIds.contains(sessionId)) continue;
      sessionIds.add(sessionId);

      final buyIns = sp['buy_in_cents_total'] as int? ?? 0;
      final cashOuts = sp['cash_out_cents'] as int? ?? 0;
      final net = cashOuts - buyIns;

      totalSessions++;
      totalBuyIns += buyIns;
      totalCashOuts += cashOuts;

      if (net > 0) {
        wins++;
        if (net > biggestWin) biggestWin = net;
      } else if (net < 0) {
        if (net < biggestLoss) biggestLoss = net;
      }
    }

    final profile = await getUserProfile(targetUserId);

    return UserProfileStats(
      userId: targetUserId,
      displayName: profile?['display_name'] as String?,
      email: null,
      totalSessions: totalSessions,
      totalBuyInsCents: totalBuyIns,
      totalCashOutsCents: totalCashOuts,
      netProfitCents: totalCashOuts - totalBuyIns,
      winRate: totalSessions > 0 ? (wins / totalSessions) * 100 : 0,
      biggestWinCents: biggestWin,
      biggestLossCents: biggestLoss,
    );
  }

  /// Determines which session IDs are accessible to the current user where the target user participated.
  ///
  /// The [groupId] parameter optionally filters to a specific group.
  ///
  /// Returns a list of session IDs where the target user actually participated.
  Future<List<int>> _getAccessibleSessionIds(
    String targetUserId, {
    int? groupId,
  }) async {
    // Database RLS defines visibility. Following no longer exposes a person's
    // financial history; only participation and current group membership do.
    final visible = groupId == null
        ? await SessionRepository().listAllVisibleSessions()
        : await SessionRepository().listSessionsInGroup(groupId);
    final ids = visible
        .where((item) => item.session.finalized)
        .map((item) => item.session.id!)
        .toList();
    if (ids.isEmpty) return [];
    final participants = await SessionRepository()
        .listSessionPlayersForMultipleSessions(ids);
    return participants
        .where((row) => row['linked_user_id'] == targetUserId)
        .map((row) => row['session_id'] as int)
        .toSet()
        .toList();
  }

  /// Get list of sessions for a user that are accessible to current user
  Future<List<UserSessionSummary>> getUserSessions(
    String targetUserId, {
    int? groupId,
  }) async {
    final accessibleSessionIds = await _getAccessibleSessionIds(
      targetUserId,
      groupId: groupId,
    );

    if (accessibleSessionIds.isEmpty) return [];

    // Get session details with player stats
    final sessions = await _client
        .from('sessions')
        .select('id, name, started_at, finalized, user_id, ledger_version')
        .inFilter('id', accessibleSessionIds)
        .order('started_at', ascending: false);

    // Get owner names
    final ownerIds = sessions
        .map((s) => s['user_id'] as String)
        .toSet()
        .toList();
    final owners = await _client
        .from('profiles')
        .select('id, display_name')
        .inFilter('id', ownerIds);
    final ownerMap = {
      for (final o in owners)
        o['id'] as String: o['display_name'] as String? ?? 'Unknown',
    };

    final sessionPlayersData =
        (await SessionRepository().listSessionPlayersForMultipleSessions(
          accessibleSessionIds,
        )).where((row) => row['linked_user_id'] == targetUserId).toList();

    final spMap = <int, Map<String, dynamic>>{};
    for (final sp in sessionPlayersData) {
      spMap[sp['session_id'] as int] = sp;
    }

    // Get group info for sessions
    final sessionGroups = await _client
        .from('session_groups')
        .select('session_id, group_id, groups(name)')
        .inFilter('session_id', accessibleSessionIds);

    final groupMap = <int, Map<String, dynamic>>{};
    for (final sg in sessionGroups) {
      groupMap[sg['session_id'] as int] = sg;
    }
    final v2Groups = await _client
        .from('sessions')
        .select('id, group_id, groups(name)')
        .inFilter('id', accessibleSessionIds)
        .not('group_id', 'is', null);
    for (final session in v2Groups) {
      groupMap[session['id'] as int] = {
        'group_id': session['group_id'],
        'groups': session['groups'],
      };
    }

    return sessions.map((s) {
      final sessionId = s['id'] as int;
      final sp = spMap[sessionId];
      final buyIns = sp?['buy_in_cents_total'] as int? ?? 0;
      final cashOuts = sp?['cash_out_cents'] as int? ?? 0;
      final sg = groupMap[sessionId];

      return UserSessionSummary(
        sessionId: sessionId,
        sessionName: s['name'] as String?,
        startedAt: DateTime.parse(s['started_at'] as String),
        finalized: s['finalized'] as bool,
        buyInsCents: buyIns,
        cashOutsCents: cashOuts,
        netCents: cashOuts - buyIns,
        ownerName: ownerMap[s['user_id'] as String] ?? 'Unknown',
        isOwner: s['user_id'] == _currentUserId,
        groupId: sg?['group_id'] as int?,
        groupName: (sg?['groups'] as Map?)?['name'] as String?,
        ledgerVersion: s['ledger_version'] as int? ?? 1,
      );
    }).toList();
  }

  /// Get groups that both current user and target user are in (mutual groups)
  Future<List<Map<String, dynamic>>> getMutualGroups(
    String targetUserId,
  ) async {
    // Get current user's groups (owned + member)
    final myOwnedGroups = await _client
        .from('groups')
        .select('id')
        .eq('owner_id', _currentUserId);

    final myMemberGroups = await _client
        .from('group_members')
        .select('group_id')
        .eq('user_id', _currentUserId);

    final myGroupIds = <int>{
      ...myOwnedGroups.map((g) => g['id'] as int),
      ...myMemberGroups.map((g) => g['group_id'] as int),
    };

    if (myGroupIds.isEmpty) return [];

    // Get target user's groups (owned + member)
    final targetOwnedGroups = await _client
        .from('groups')
        .select('id')
        .eq('owner_id', targetUserId);

    final targetMemberGroups = await _client
        .from('group_members')
        .select('group_id')
        .eq('user_id', targetUserId);

    final targetGroupIds = <int>{
      ...targetOwnedGroups.map((g) => g['id'] as int),
      ...targetMemberGroups.map((g) => g['group_id'] as int),
    };

    // Find intersection (mutual groups)
    final mutualIds = myGroupIds.intersection(targetGroupIds).toList();

    if (mutualIds.isEmpty) return [];

    // Get group details
    final groups = await _client
        .from('groups')
        .select('id, name')
        .inFilter('id', mutualIds);

    return groups;
  }

  /// Get groups that current user has access to (for filtering)
  Future<List<Map<String, dynamic>>> getAccessibleGroups() async {
    final ownedGroups = await _client
        .from('groups')
        .select('id, name')
        .eq('owner_id', _currentUserId);

    final memberGroupIds = await _client
        .from('group_members')
        .select('group_id')
        .eq('user_id', _currentUserId);

    final memberIds = memberGroupIds.map((g) => g['group_id'] as int).toList();

    List<Map<String, dynamic>> memberGroups = [];
    if (memberIds.isNotEmpty) {
      memberGroups = await _client
          .from('groups')
          .select('id, name')
          .inFilter('id', memberIds);
    }

    return [...ownedGroups, ...memberGroups];
  }
}
