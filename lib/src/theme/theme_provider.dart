import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Provider for the current theme mode setting
final themeModeProvider = StateNotifierProvider<ThemeModeNotifier, ThemeMode>((ref) {
  return ThemeModeNotifier();
});

/// Notifier for managing theme mode state
class ThemeModeNotifier extends StateNotifier<ThemeMode> {
  ThemeModeNotifier() : super(ThemeMode.system) {
    _loadThemeMode();
  }
  
  /// Load theme mode from user's profile settings
  Future<void> _loadThemeMode() async {
    final user = Supabase.instance.client.auth.currentUser;
    if (user == null) {
      state = ThemeMode.system;
      return;
    }
    
    try {
      final data = await Supabase.instance.client
          .from('profiles')
          .select('theme_mode')
          .eq('id', user.id)
          .maybeSingle();
      
      final themeMode = data?['theme_mode'] as String? ?? 'system';
      state = _parseThemeMode(themeMode);
    } catch (e) {
      state = ThemeMode.system;
    }
  }
  
  /// Update theme mode and persist to database
  Future<void> setThemeMode(String mode) async {
    state = _parseThemeMode(mode);
    
    final user = Supabase.instance.client.auth.currentUser;
    if (user != null) {
      await Supabase.instance.client
          .from('profiles')
          .update({'theme_mode': mode})
          .eq('id', user.id);
    }
  }
  
  /// Reload theme from database (e.g., after login)
  void reload() {
    _loadThemeMode();
  }
  
  ThemeMode _parseThemeMode(String mode) {
    switch (mode) {
      case 'light':
        return ThemeMode.light;
      case 'dark':
        return ThemeMode.dark;
      default:
        return ThemeMode.system;
    }
  }
}
