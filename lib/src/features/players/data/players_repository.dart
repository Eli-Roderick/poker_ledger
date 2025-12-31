import 'package:supabase_flutter/supabase_flutter.dart';
import '../domain/player.dart';

class PlayersRepository {
  final SupabaseClient _client = Supabase.instance.client;

  Future<List<Player>> getAll({bool includeDeactivated = false, bool deactivatedOnly = false}) async {
    var query = _client.from('players').select();
    
    if (deactivatedOnly) {
      query = query.eq('active', false);
    } else if (!includeDeactivated) {
      query = query.eq('active', true);
    }
    
    final data = await query.order('created_at', ascending: false);
    return (data as List).map((e) => Player.fromMap(e)).toList();
  }

  Future<Player> add({
    required String name,
    String? email,
    String? phone,
    String? notes,
  }) async {
    final data = await _client.from('players').insert({
      'user_id': _client.auth.currentUser!.id,
      'name': name,
      'email': email,
      'phone': phone,
      'notes': notes,
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
}
