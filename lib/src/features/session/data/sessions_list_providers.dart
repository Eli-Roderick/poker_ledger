import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../auth/providers/auth_providers.dart';
import '../domain/session_models.dart';
import 'session_repository.dart';
import 'session_providers.dart' show sessionRepositoryProvider;

class SessionsListNotifier extends AsyncNotifier<List<SessionWithOwner>> {
  SessionRepository get _repo => ref.read(sessionRepositoryProvider);

  @override
  Future<List<SessionWithOwner>> build() async {
    // Watch auth state to auto-refresh when user changes
    final user = ref.watch(currentUserProvider);
    if (user == null) return [];

    return _repo.listMyGames();
  }

  Future<void> refresh() async {
    state = const AsyncLoading();
    state = await AsyncValue.guard(_repo.listMyGames);
  }

  Future<void> removeSessionOptimistically(int sessionId) async {
    final currentState = state;
    if (currentState is AsyncData && currentState.value != null) {
      state = AsyncData(
        currentState.value!
            .where((session) => session.session.id != sessionId)
            .toList(),
      );
    }
  }
}

final sessionsListProvider =
    AsyncNotifierProvider<SessionsListNotifier, List<SessionWithOwner>>(
      () => SessionsListNotifier(),
    );
