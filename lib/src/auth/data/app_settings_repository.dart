import 'package:supabase_flutter/supabase_flutter.dart';

class AppSettingsRepository {
  final SupabaseClient _client = Supabase.instance.client;

  /// Get maintenance mode status from database
  /// Returns true if maintenance mode is enabled
  Future<bool> getMaintenanceMode() async {
    try {
      final data = await _client
          .from('app_settings')
          .select('value')
          .eq('key', 'maintenance_mode')
          .maybeSingle();
      
      if (data == null) return false;
      return data['value'] == 'true';
    } catch (e) {
      // If table doesn't exist or error, default to false
      return false;
    }
  }

  /// Set maintenance mode status (admin only)
  Future<void> setMaintenanceMode(bool enabled) async {
    await _client.from('app_settings').upsert({
      'key': 'maintenance_mode',
      'value': enabled.toString(),
    }, onConflict: 'key');
  }
}
