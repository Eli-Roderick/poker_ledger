import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../auth/providers/auth_providers.dart';
import 'players_repository.dart';
import '../domain/player.dart';

final playersRepositoryProvider = Provider<PlayersRepository>((ref) {
  return PlayersRepository();
});

class PlayersListNotifier extends AsyncNotifier<List<Player>> {
  PlayersListNotifier();

  PlayersRepository get _repo => ref.read(playersRepositoryProvider);
  bool _showDeactivated = false;
  bool get showDeactivated => _showDeactivated;

  @override
  Future<List<Player>> build() async {
    // Watch auth state to auto-refresh when user changes
    final user = ref.watch(currentUserProvider);
    if (user == null) return [];
    
    return _repo.getAll(includeDeactivated: _showDeactivated, deactivatedOnly: _showDeactivated);
  }

  Future<void> refresh() async {
    state = const AsyncLoading();
    state = await AsyncValue.guard(() => _repo.getAll(includeDeactivated: _showDeactivated, deactivatedOnly: _showDeactivated));
  }

  Future<void> addPlayer({
    required String name,
    String? email,
    String? phone,
    String? notes,
    String? linkedUserId,
  }) async {
    final added = await _repo.add(name: name, email: email, phone: phone, notes: notes, linkedUserId: linkedUserId);
    final current = state.value ?? const <Player>[];
    state = AsyncData(<Player>[added, ...current]);
  }

  Future<List<UserSearchResult>> searchUsers(String query) async {
    return _repo.searchUsers(query);
  }

  /// Search through user's linked players (for group invites)
  /// If excludeGroupId is provided, excludes players already in that group
  Future<List<Player>> searchLinkedPlayers(String query, {int? excludeGroupId}) async {
    return _repo.searchLinkedPlayers(query, excludeGroupId: excludeGroupId);
  }

  Future<void> linkPlayerToUser({required int playerId, required String userId}) async {
    await _repo.linkToUser(playerId: playerId, userId: userId);
    await refresh();
  }

  Future<void> unlinkPlayer({required int playerId}) async {
    await _repo.unlinkUser(playerId: playerId);
    await refresh();
  }

  Future<void> deletePlayer(int id) async {
    await _repo.delete(id);
    final current = state.value ?? const <Player>[];
    state = AsyncData(current.where((e) => e.id != id).toList());
  }

  Future<void> updatePlayer({
    required int id,
    required String name,
    String? email,
    String? phone,
    String? notes,
  }) async {
    final updated = await _repo.update(id: id, name: name, email: email, phone: phone, notes: notes);
    final current = state.value ?? const <Player>[];
    final next = current.map((p) => p.id == id ? updated : p).toList();
    state = AsyncData(next);
  }

  Future<void> setActive({required int id, required bool active}) async {
    await _repo.setActive(id: id, active: active);
    await refresh();
  }

  Future<void> toggleShowDeactivated() async {
    _showDeactivated = !_showDeactivated;
    await refresh();
  }
}

final playersListProvider = AsyncNotifierProvider<PlayersListNotifier, List<Player>>(
  () => PlayersListNotifier(),
);
