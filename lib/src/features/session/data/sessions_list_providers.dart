import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/session_models.dart';
import 'session_repository.dart';
import 'session_providers.dart' show sessionRepositoryProvider;

class SessionsListNotifier extends AsyncNotifier<List<Session>> {
  late final SessionRepository _repo;
  @override
  Future<List<Session>> build() async {
    _repo = ref.read(sessionRepositoryProvider);
    return _repo.listSessions();
  }

  Future<void> refresh() async {
    state = const AsyncLoading();
    state = AsyncData(await _repo.listSessions());
  }
}

final sessionsListProvider = AsyncNotifierProvider<SessionsListNotifier, List<Session>>(
  () => SessionsListNotifier(),
);
