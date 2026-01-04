import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../auth/providers/auth_providers.dart';
import '../../session/data/session_repository.dart';
import '../../session/domain/session_models.dart';

class SummaryFilters {
  final DateTimeRange? range;
  final bool includeInProgress;
  const SummaryFilters({this.range, this.includeInProgress = false});

  SummaryFilters copyWith({DateTimeRange? range, bool? includeInProgress}) => SummaryFilters(
        range: range ?? this.range,
        includeInProgress: includeInProgress ?? this.includeInProgress,
      );
}

class DateTimeRange {
  final DateTime start;
  final DateTime end;
  const DateTimeRange({required this.start, required this.end});

  bool contains(DateTime dt) => !dt.isBefore(start) && !dt.isAfter(end);
}

class SessionSummaryEntry {
  final Session session;
  final int buyInsTotalCents;
  final int cashOutsTotalCents;
  int get diffCents => cashOutsTotalCents - buyInsTotalCents;
  const SessionSummaryEntry({required this.session, required this.buyInsTotalCents, required this.cashOutsTotalCents});
}

class SummaryState {
  final SummaryFilters filters;
  final List<SessionSummaryEntry> entries;
  int get globalBuyInsCents => entries.fold(0, (p, e) => p + e.buyInsTotalCents);
  int get globalCashOutsCents => entries.fold(0, (p, e) => p + e.cashOutsTotalCents);
  int get globalDiffCents => globalCashOutsCents - globalBuyInsCents;

  const SummaryState({required this.filters, required this.entries});
}

final summaryRepositoryProvider = Provider<SessionRepository>((ref) => SessionRepository());

class SummaryNotifier extends AsyncNotifier<SummaryState> {
  late final SessionRepository _repo;
  SummaryFilters _filters = SummaryFilters(
    range: DateTimeRange(
      start: DateTime.now().subtract(const Duration(days: 30)),
      end: DateTime.now(),
    ),
    includeInProgress: false,
  );

  @override
  Future<SummaryState> build() async {
    // Watch auth state to auto-refresh when user changes
    final user = ref.watch(currentUserProvider);
    if (user == null) {
      return SummaryState(filters: _filters, entries: []);
    }
    
    _repo = ref.read(summaryRepositoryProvider);
    return _load();
  }

  Future<void> setFilters(SummaryFilters filters) async {
    _filters = filters;
    state = const AsyncLoading();
    state = await AsyncValue.guard(() async => _load());
  }

  Future<SummaryState> _load() async {
    final sessions = await _repo.listSessions();
    final filtered = sessions.where((s) {
      final inRange = _filters.range == null
          ? true
          : _filters.range!.contains(s.startedAt);
      final include = _filters.includeInProgress ? true : s.finalized;
      return inRange && include;
    }).toList();

    final entries = <SessionSummaryEntry>[];
    for (final s in filtered) {
      final rows = await _repo.listSessionPlayersWithNames(s.id!);
      int buyIns = 0;
      int cashOuts = 0;
      for (final r in rows) {
        buyIns += (r['buy_in_cents_total'] as int?) ?? 0;
        cashOuts += (r['cash_out_cents'] as int?) ?? 0;
      }
      entries.add(SessionSummaryEntry(session: s, buyInsTotalCents: buyIns, cashOutsTotalCents: cashOuts));
    }

    return SummaryState(filters: _filters, entries: entries);
  }
}

final summaryProvider = AsyncNotifierProvider<SummaryNotifier, SummaryState>(() => SummaryNotifier());
