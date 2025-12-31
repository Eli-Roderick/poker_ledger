import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/session_models.dart';
import 'session_repository.dart';
import 'session_providers.dart' show sessionRepositoryProvider;

/// Filter for which sessions to show
enum SessionSourceFilter {
  mySessions,  // Only sessions created by current user
  all,         // All visible sessions (own + shared via groups)
  group,       // Sessions in a specific group
}

class SessionsFilterState {
  final SessionSourceFilter source;
  final int? groupId;
  final String? groupName;

  const SessionsFilterState({
    this.source = SessionSourceFilter.mySessions,
    this.groupId,
    this.groupName,
  });

  SessionsFilterState copyWith({
    SessionSourceFilter? source,
    int? groupId,
    String? groupName,
  }) =>
      SessionsFilterState(
        source: source ?? this.source,
        groupId: groupId ?? this.groupId,
        groupName: groupName ?? this.groupName,
      );
}

final sessionsSourceFilterProvider = StateProvider<SessionsFilterState>(
  (ref) => const SessionsFilterState(),
);

class SessionsListNotifier extends AsyncNotifier<List<SessionWithOwner>> {
  late final SessionRepository _repo;

  @override
  Future<List<SessionWithOwner>> build() async {
    _repo = ref.read(sessionRepositoryProvider);
    final filter = ref.watch(sessionsSourceFilterProvider);
    return _loadSessions(filter);
  }

  Future<List<SessionWithOwner>> _loadSessions(SessionsFilterState filter) async {
    switch (filter.source) {
      case SessionSourceFilter.mySessions:
        final sessions = await _repo.listMySessions();
        return sessions.map((s) => SessionWithOwner(
          session: s,
          ownerName: 'You',
          isOwner: true,
        )).toList();
      case SessionSourceFilter.all:
        return _repo.listAllVisibleSessions();
      case SessionSourceFilter.group:
        if (filter.groupId == null) {
          return [];
        }
        return _repo.listSessionsInGroup(filter.groupId!);
    }
  }

  Future<void> refresh() async {
    state = const AsyncLoading();
    final filter = ref.read(sessionsSourceFilterProvider);
    state = AsyncData(await _loadSessions(filter));
  }
}

final sessionsListProvider = AsyncNotifierProvider<SessionsListNotifier, List<SessionWithOwner>>(
  () => SessionsListNotifier(),
);
