import 'package:supabase_flutter/supabase_flutter.dart';

class PlayerDetailRepository {
  final SupabaseClient _client = Supabase.instance.client;

  Future<void> addQuickAdd({required int playerId, required int amountCents, String? note}) async {
    await _client.from('quick_add_entries').insert({
      'user_id': _client.auth.currentUser!.id,
      'player_id': playerId,
      'amount_cents': amountCents,
      'note': note,
    });
  }

  Future<List<Map<String, Object?>>> listQuickAdds(int playerId) async {
    final data = await _client
        .from('quick_add_entries')
        .select()
        .eq('player_id', playerId)
        .order('created_at', ascending: false);
    return List<Map<String, Object?>>.from(data);
  }

  Future<void> deleteQuickAdd(int id) async {
    await _client.from('quick_add_entries').delete().eq('id', id);
  }

  Future<List<Map<String, Object?>>> listPlayerSessionNets(int playerId) async {
    final data = await _client
        .from('session_players')
        .select('session_id, buy_in_cents_total, cash_out_cents, sessions(id, name, started_at)')
        .eq('player_id', playerId);
    
    return (data as List).map((row) {
      final session = row['sessions'] as Map<String, dynamic>?;
      final buyIn = row['buy_in_cents_total'] as int? ?? 0;
      final cashOut = row['cash_out_cents'] as int? ?? 0;
      return {
        'session_id': row['session_id'],
        'session_name': session?['name'],
        'started_at': session?['started_at'],
        'net_cents': cashOut - buyIn,
      };
    }).toList()
      ..sort((a, b) {
        final aDate = a['started_at'] as String?;
        final bDate = b['started_at'] as String?;
        if (aDate == null || bDate == null) return 0;
        return bDate.compareTo(aDate);
      });
  }

  Future<int> totalBuyInCents(int playerId) async {
    final data = await _client
        .from('session_players')
        .select('buy_in_cents_total')
        .eq('player_id', playerId);
    
    int total = 0;
    for (final row in data) {
      total += (row['buy_in_cents_total'] as int? ?? 0);
    }
    return total;
  }
}
