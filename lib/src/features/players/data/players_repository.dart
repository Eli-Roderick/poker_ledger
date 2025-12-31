import 'package:supabase_flutter/supabase_flutter.dart';
import '../domain/player.dart';

class PlayersRepository {
  final SupabaseClient _client = Supabase.instance.client;

  Future<List<Player>> getAll({bool includeDeactivated = false, bool deactivatedOnly = false}) async {
    // Only show players owned by the current user (not linked players from other users)
    var query = _client.from('players').select().eq('user_id', _client.auth.currentUser!.id);
    
    if (deactivatedOnly) {
      query = query.eq('active', false);
    } else if (!includeDeactivated) {
      query = query.eq('active', true);
    }
    
    final data = await query.order('created_at', ascending: false);
    
    // Fetch linked user display names
    final players = <Player>[];
    for (final e in data) {
      final linkedUserId = e['linked_user_id'] as String?;
      String? linkedUserDisplayName;
      if (linkedUserId != null) {
        final profile = await _client
            .from('profiles')
            .select('display_name')
            .eq('id', linkedUserId)
            .maybeSingle();
        linkedUserDisplayName = profile?['display_name'] as String?;
      }
      players.add(Player.fromMap({
        ...e,
        'linked_user_display_name': linkedUserDisplayName,
      }));
    }
    return players;
  }

  Future<Player> add({
    required String name,
    String? email,
    String? phone,
    String? notes,
    String? linkedUserId,
  }) async {
    final data = await _client.from('players').insert({
      'user_id': _client.auth.currentUser!.id,
      'name': name,
      'email': email,
      'phone': phone,
      'notes': notes,
      'linked_user_id': linkedUserId,
    }).select().single();
    return Player.fromMap(data);
  }

  Future<void> delete(int id) async {
    await _client.from('players').delete().eq('id', id);
  }

  Future<void> setActive({required int id, required bool active}) async {
    await _client.from('players').update({'active': active}).eq('id', id);
  }

  Future<Player> update({
    required int id,
    required String name,
    String? email,
    String? phone,
    String? notes,
  }) async {
    final data = await _client.from('players').update({
      'name': name,
      'email': email,
      'phone': phone,
      'notes': notes,
    }).eq('id', id).select().single();
    return Player.fromMap(data);
  }

  /// Link a player to a user account
  Future<void> linkToUser({required int playerId, required String userId}) async {
    await _client.from('players').update({
      'linked_user_id': userId,
    }).eq('id', playerId);
  }

  /// Unlink a player from a user account
  Future<void> unlinkUser({required int playerId}) async {
    await _client.from('players').update({
      'linked_user_id': null,
    }).eq('id', playerId);
  }

  /// Search for users by email or display name
  Future<List<UserSearchResult>> searchUsers(String query) async {
    if (query.trim().isEmpty) return [];
    
    final searchTerm = '%${query.toLowerCase().trim()}%';
    
    final data = await _client
        .from('profiles')
        .select('id, display_name, email')
        .or('email.ilike.$searchTerm,display_name.ilike.$searchTerm')
        .limit(10);
    
    return (data as List).map((e) => UserSearchResult.fromMap(e)).toList();
  }

  /// Get a single player by ID with linked user info
  Future<Player?> getById(int id) async {
    final data = await _client
        .from('players')
        .select()
        .eq('id', id)
        .maybeSingle();
    
    if (data == null) return null;
    
    final linkedUserId = data['linked_user_id'] as String?;
    String? linkedUserDisplayName;
    if (linkedUserId != null) {
      final profile = await _client
          .from('profiles')
          .select('display_name')
          .eq('id', linkedUserId)
          .maybeSingle();
      linkedUserDisplayName = profile?['display_name'] as String?;
    }
    
    return Player.fromMap({
      ...data,
      'linked_user_display_name': linkedUserDisplayName,
    });
  }
}
