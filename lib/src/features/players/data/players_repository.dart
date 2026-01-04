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
    // Only delete players owned by the current user
    await _client
        .from('players')
        .delete()
        .eq('id', id)
        .eq('user_id', _client.auth.currentUser!.id);
  }

  Future<void> setActive({required int id, required bool active}) async {
    // Only update players owned by the current user
    await _client
        .from('players')
        .update({'active': active})
        .eq('id', id)
        .eq('user_id', _client.auth.currentUser!.id);
  }

  Future<Player> update({
    required int id,
    required String name,
    String? email,
    String? phone,
    String? notes,
  }) async {
    // Only update players owned by the current user
    final data = await _client.from('players').update({
      'name': name,
      'email': email,
      'phone': phone,
      'notes': notes,
    }).eq('id', id).eq('user_id', _client.auth.currentUser!.id).select().single();
    return Player.fromMap(data);
  }

  /// Link a player to a user account
  Future<void> linkToUser({required int playerId, required String userId}) async {
    // Only update players owned by the current user
    await _client.from('players').update({
      'linked_user_id': userId,
    }).eq('id', playerId).eq('user_id', _client.auth.currentUser!.id);
  }

  /// Unlink a player from a user account
  Future<void> unlinkUser({required int playerId}) async {
    // Only update players owned by the current user
    await _client.from('players').update({
      'linked_user_id': null,
    }).eq('id', playerId).eq('user_id', _client.auth.currentUser!.id);
  }

  /// Search for users by email or display name, excluding users already added as ACTIVE players
  /// Deactivated players will still show up so users can reactivate them
  Future<List<UserSearchResult>> searchUsers(String query) async {
    if (query.trim().isEmpty) return [];
    
    // Get all linked_user_ids for current user's ACTIVE players to exclude them
    final existingActivePlayers = await _client
        .from('players')
        .select('linked_user_id')
        .eq('user_id', _client.auth.currentUser!.id)
        .eq('active', true)
        .not('linked_user_id', 'is', null);
    
    final activeLinkedIds = existingActivePlayers
        .map((e) => e['linked_user_id'] as String)
        .toSet();
    
    // Get deactivated players that match the search to show reactivation option
    final deactivatedPlayers = await _client
        .from('players')
        .select('id, linked_user_id')
        .eq('user_id', _client.auth.currentUser!.id)
        .eq('active', false)
        .not('linked_user_id', 'is', null);
    
    final deactivatedLinkedIds = {
      for (final p in deactivatedPlayers)
        p['linked_user_id'] as String: p['id'] as int
    };
    
    final searchTerm = '%${query.toLowerCase().trim()}%';
    
    final data = await _client
        .from('profiles')
        .select('id, display_name, email')
        .or('email.ilike.$searchTerm,display_name.ilike.$searchTerm')
        .limit(20);
    
    // Filter out users already added as ACTIVE players
    // But include deactivated players with a flag
    return (data as List)
        .where((e) => !activeLinkedIds.contains(e['id'] as String))
        .map((e) {
          final userId = e['id'] as String;
          final deactivatedPlayerId = deactivatedLinkedIds[userId];
          return UserSearchResult.fromMap(e, deactivatedPlayerId: deactivatedPlayerId);
        })
        .take(10)
        .toList();
  }

  /// Search through user's linked players by name or email
  /// This is used for group invites - searches players you've added, not all users
  Future<List<Player>> searchLinkedPlayers(String query) async {
    if (query.trim().isEmpty) return [];
    
    final searchTerm = '%${query.toLowerCase().trim()}%';
    
    // Search only the current user's players that are linked to accounts
    final data = await _client
        .from('players')
        .select()
        .eq('user_id', _client.auth.currentUser!.id)
        .not('linked_user_id', 'is', null)
        .or('name.ilike.$searchTerm,email.ilike.$searchTerm')
        .limit(10);
    
    // Batch fetch linked user display names
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

  /// Check if a user is already in the current user's player list
  /// Returns the player if found (including deactivated), null otherwise
  Future<Player?> getPlayerByLinkedUserId(String linkedUserId) async {
    final data = await _client
        .from('players')
        .select()
        .eq('user_id', _client.auth.currentUser!.id)
        .eq('linked_user_id', linkedUserId)
        .maybeSingle();
    
    if (data == null) return null;
    
    // Get display name
    final profile = await _client
        .from('profiles')
        .select('display_name')
        .eq('id', linkedUserId)
        .maybeSingle();
    
    return Player.fromMap({
      ...data,
      'linked_user_display_name': profile?['display_name'] as String?,
    });
  }

  /// Add a user as a player, or reactivate if already exists but deactivated
  /// Returns the player and whether it was newly created (false = reactivated)
  Future<({Player player, bool isNew})> addOrReactivateLinkedUser({
    required String userId,
    required String displayName,
    String? email,
  }) async {
    // Check if already exists
    final existing = await getPlayerByLinkedUserId(userId);
    
    if (existing != null) {
      // Reactivate if deactivated
      if (!existing.active && existing.id != null) {
        await setActive(id: existing.id!, active: true);
        return (player: existing.copyWith(active: true), isNew: false);
      }
      // Already active - return as-is
      return (player: existing, isNew: false);
    }
    
    // Create new player
    final player = await add(
      name: displayName,
      email: email,
      linkedUserId: userId,
    );
    return (player: player, isNew: true);
  }
}
