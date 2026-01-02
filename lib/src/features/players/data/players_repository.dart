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
    
    // Batch fetch all linked user display names in one query
    final linkedUserIds = data
        .map((e) => e['linked_user_id'] as String?)
        .where((id) => id != null)
        .cast<String>()
        .toSet()
        .toList();
    
    Map<String, String> displayNameById = {};
    if (linkedUserIds.isNotEmpty) {
      final profiles = await _client
          .from('profiles')
          .select('id, display_name')
          .inFilter('id', linkedUserIds);
      displayNameById = {
        for (final p in profiles)
          p['id'] as String: p['display_name'] as String? ?? 'Unknown'
      };
    }
    
    return data.map((e) {
      final linkedUserId = e['linked_user_id'] as String?;
      return Player.fromMap({
        ...e,
        'linked_user_display_name': linkedUserId != null ? displayNameById[linkedUserId] : null,
      });
    }).toList();
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

  /// Search for users by email or display name, excluding users already added as players
  Future<List<UserSearchResult>> searchUsers(String query) async {
    if (query.trim().isEmpty) return [];
    
    // Get all linked_user_ids for current user's players to exclude them
    final existingPlayers = await _client
        .from('players')
        .select('linked_user_id')
        .eq('user_id', _client.auth.currentUser!.id)
        .not('linked_user_id', 'is', null);
    
    final existingLinkedIds = existingPlayers
        .map((e) => e['linked_user_id'] as String)
        .toSet();
    
    final searchTerm = '%${query.toLowerCase().trim()}%';
    
    final data = await _client
        .from('profiles')
        .select('id, display_name, email')
        .or('email.ilike.$searchTerm,display_name.ilike.$searchTerm')
        .limit(20);  // Fetch more to account for filtering
    
    // Filter out users already added as players
    return (data as List)
        .where((e) => !existingLinkedIds.contains(e['id'] as String))
        .map((e) => UserSearchResult.fromMap(e))
        .take(10)
        .toList();
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
