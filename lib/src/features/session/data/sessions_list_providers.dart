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
    // Sessions list only shows user's own sessions
    // Shared sessions only appear in Analytics when filtering by group
    final sessions = await _repo.listMySessions();
    return sessions.map((s) => SessionWithOwner(
      session: s,
      ownerName: 'You',
      isOwner: true,
    )).toList();
  }

  Future<void> refresh() async {
    state = const AsyncLoading();
    final sessions = await _repo.listMySessions();
    state = AsyncData(sessions.map((s) => SessionWithOwner(
      session: s,
      ownerName: 'You',
      isOwner: true,
    )).toList());
  }
}

final sessionsListProvider = AsyncNotifierProvider<SessionsListNotifier, List<SessionWithOwner>>(
  () => SessionsListNotifier(),
);
