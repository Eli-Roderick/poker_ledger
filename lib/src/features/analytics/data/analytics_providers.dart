import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../session/data/session_repository.dart';
import '../../session/domain/session_models.dart';

class AnalyticsFilters {
  final DateTime? start;
  final DateTime? end;
  final bool includeInProgress;
  final int? groupId;
  final String? groupName;
  const AnalyticsFilters({this.start, this.end, this.includeInProgress = false, this.groupId, this.groupName});

  bool _inRange(DateTime d) {
    final afterStart = start == null || !d.isBefore(start!);
    final beforeEnd = end == null || !d.isAfter(end!);
    return afterStart && beforeEnd;
  }

  AnalyticsFilters copyWith({DateTime? start, DateTime? end, bool? includeInProgress, int? groupId, String? groupName}) => AnalyticsFilters(
        start: start ?? this.start,
        end: end ?? this.end,
        includeInProgress: includeInProgress ?? this.includeInProgress,
        groupId: groupId ?? this.groupId,
        groupName: groupName ?? this.groupName,
      );
  
  AnalyticsFilters clearGroup() => AnalyticsFilters(
        start: start,
        end: end,
        includeInProgress: includeInProgress,
        groupId: null,
        groupName: null,
      );
}

class PlayerAggregate {
  final int playerId;
  final String playerName;
  final int sessions;
  final int netCents; // cash-outs - buy-ins across filtered sessions
  final int maxSingleWinCents; // best single-session net
  final int maxSingleLossCents; // worst single-session net (negative or 0)
  final bool active; // current activation status (for leaderboards)
  const PlayerAggregate({
    required this.playerId,
    required this.playerName,
    required this.sessions,
    required this.netCents,
    required this.maxSingleWinCents,
    required this.maxSingleLossCents,
    required this.active,
  });
}

class SessionKPI {
  final Session session;
  final int players;
  final int buyInsCents;
  final int cashOutsCents;
  final String? ownerName; // For shared sessions - shows who shared it
  final bool isOwner;
  int get netCents => cashOutsCents - buyInsCents;
  const SessionKPI({
    required this.session,
    required this.players,
    required this.buyInsCents,
    required this.cashOutsCents,
    this.ownerName,
    this.isOwner = true,
  });
}

class AnalyticsState {
  final AnalyticsFilters filters;
  final List<PlayerAggregate> players;
  final List<SessionKPI> sessions;
  int get totalSessions => sessions.length;
  int get totalPlayersSeen => players.length;
  int get globalNetCents => sessions.fold(0, (p, e) => p + e.netCents);
  const AnalyticsState({required this.filters, required this.players, required this.sessions});
}

final analyticsRepoProvider = Provider<SessionRepository>((ref) => SessionRepository());

class AnalyticsNotifier extends AsyncNotifier<AnalyticsState> {
  AnalyticsFilters _filters = const AnalyticsFilters(
    start: null,
    end: null,
    includeInProgress: false,
  );

  @override
  Future<AnalyticsState> build() async {
    return _load();
  }

  Future<void> setFilters(AnalyticsFilters f) async {
    _filters = f;
    state = const AsyncLoading();
    state = await AsyncValue.guard(() async => _load());
  }

  Future<void> refresh() async {
    // Advance the window end to now, so recently started sessions are included
    _filters = _filters.copyWith(end: DateTime.now());
    state = const AsyncLoading();
    state = await AsyncValue.guard(() async => _load());
  }

  Future<AnalyticsState> _load() async {
    final repo = ref.read(analyticsRepoProvider);
    
    // Get sessions based on group filter
    List<SessionWithOwner> sessionsWithOwner;
    if (_filters.groupId != null) {
      sessionsWithOwner = await repo.listSessionsInGroup(_filters.groupId!);
    } else {
      final mySessions = await repo.listMySessions();
      sessionsWithOwner = mySessions.map((s) => SessionWithOwner(
        session: s,
        ownerName: 'You',
        isOwner: true,
      )).toList();
    }
    
    final filtered = sessionsWithOwner.where((sw) {
      final inRange = _filters._inRange(sw.session.startedAt);
      final include = _filters.includeInProgress ? true : sw.session.finalized;
      return inRange && include;
    }).toList();

    // Batch fetch all session players in one query for performance
    final sessionIds = filtered.map((sw) => sw.session.id!).toList();
    final allSessionPlayers = await repo.listSessionPlayersForMultipleSessions(sessionIds);
    
    // Group by session_id for easy lookup
    final playersBySession = <int, List<Map<String, Object?>>>{};
    for (final row in allSessionPlayers) {
      final sid = row['session_id'] as int;
      playersBySession.putIfAbsent(sid, () => []).add(row);
    }

    // Build per-session aggregates (include deactivated players to preserve history)
    final sessionKpis = <SessionKPI>[];
    final playerMap = <int, PlayerAggregate>{};
    for (final sw in filtered) {
      final s = sw.session;
      final rows = playersBySession[s.id!] ?? [];
      int buy = 0, cash = 0;
      for (final r in rows) {
        final pid = r['player_id'] as int;
        final name = (r['player_name'] as String?) ?? 'Unknown';
        final b = (r['buy_in_cents_total'] as int?) ?? 0;
        final c = (r['cash_out_cents'] as int?) ?? 0;
        final net = c - b;
        buy += b;
        cash += c;
        final prev = playerMap[pid];
        if (prev == null) {
          playerMap[pid] = PlayerAggregate(
            playerId: pid,
            playerName: name,
            sessions: 1,
            netCents: net,
            maxSingleWinCents: net > 0 ? net : 0,
            maxSingleLossCents: net < 0 ? net : 0,
            active: true, // placeholder; will be replaced with actual active status later
          );
        } else {
          playerMap[pid] = PlayerAggregate(
            playerId: pid,
            playerName: prev.playerName,
            sessions: prev.sessions + 1,
            netCents: prev.netCents + net,
            maxSingleWinCents: net > prev.maxSingleWinCents ? net : prev.maxSingleWinCents,
            maxSingleLossCents: net < prev.maxSingleLossCents ? net : prev.maxSingleLossCents,
            active: prev.active,
          );
        }
      }
      sessionKpis.add(SessionKPI(
        session: s,
        players: rows.length,
        buyInsCents: buy,
        cashOutsCents: cash,
        ownerName: sw.ownerName,
        isOwner: sw.isOwner,
      ));
    }

    // Add quick-add totals to player nets (does not change sessions/max win/max loss)
    final quickAddRows = await repo.listQuickAddSumsByPlayer();
    // Map player id -> name and active for players not present in sessions (include deactivated for historical quick-adds)
    final allPlayers = await repo.getAllPlayers();
    final nameById = {for (final pl in allPlayers) pl.id!: pl.name};
    final activeById = {for (final pl in allPlayers) pl.id!: (pl.active)};
    for (final row in quickAddRows) {
      final pid = row['player_id'] as int;
      final adj = (row['total_cents'] as int?) ?? 0;
      if (adj == 0) continue;
      final prev = playerMap[pid];
      if (prev == null) {
        // Player has only quick-adds in the filtered range; sessions = 0, maxes = 0
        final name = nameById[pid] ?? 'Unknown';
        playerMap[pid] = PlayerAggregate(
          playerId: pid,
          playerName: name,
          sessions: 0,
          netCents: adj,
          maxSingleWinCents: 0,
          maxSingleLossCents: 0,
          active: activeById[pid] ?? true,
        );
      } else {
        playerMap[pid] = PlayerAggregate(
          playerId: pid,
          playerName: prev.playerName,
          sessions: prev.sessions,
          netCents: prev.netCents + adj,
          maxSingleWinCents: prev.maxSingleWinCents,
          maxSingleLossCents: prev.maxSingleLossCents,
          active: prev.active,
        );
      }
    }

    // Attach accurate active flags to all aggregates
    final players = playerMap.values.map((agg) {
      final isActive = activeById[agg.playerId] ?? true;
      return PlayerAggregate(
        playerId: agg.playerId,
        playerName: agg.playerName,
        sessions: agg.sessions,
        netCents: agg.netCents,
        maxSingleWinCents: agg.maxSingleWinCents,
        maxSingleLossCents: agg.maxSingleLossCents,
        active: isActive,
      );
    }).toList()
      ..sort((a, b) => b.netCents.compareTo(a.netCents));

    return AnalyticsState(filters: _filters, players: players, sessions: sessionKpis);
  }
}

final analyticsProvider = AsyncNotifierProvider<AnalyticsNotifier, AnalyticsState>(() => AnalyticsNotifier());
