import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'src/auth/presentation/auth_gate.dart';
import 'src/theme/app_theme.dart';
import 'src/theme/theme_provider.dart';
import 'src/utils/web_keyboard_fix.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  
  // Enable edge-to-edge mode for better keyboard handling
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  
  await Supabase.initialize(
    url: 'https://rgalzgiizhtwzwkfasoc.supabase.co',
    anonKey: 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InJnYWx6Z2lpemh0d3p3a2Zhc29jIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NjcxNTExMzEsImV4cCI6MjA4MjcyNzEzMX0.mhwELAeFPVT7oOdUU7KipFSxJFrTNocb9-98PWjxHsc',
  );
  
  runApp(const ProviderScope(child: MyApp()));
}

class MyApp extends ConsumerWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final themeMode = ref.watch(themeModeProvider);
    
    // Update system UI based on theme
    final isDark = themeMode == ThemeMode.dark || 
        (themeMode == ThemeMode.system && 
         MediaQuery.platformBrightnessOf(context) == Brightness.dark);
    
    SystemChrome.setSystemUIOverlayStyle(SystemUiOverlayStyle(
      systemNavigationBarColor: isDark ? const Color(0xFF111315) : Colors.white,
      systemNavigationBarDividerColor: isDark ? const Color(0xFF111315) : Colors.white,
      systemNavigationBarIconBrightness: isDark ? Brightness.light : Brightness.dark,
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: isDark ? Brightness.light : Brightness.dark,
    ));
    
    return MaterialApp(
      title: 'Poker Ledger',
      theme: AppTheme.lightTheme(),
      darkTheme: AppTheme.darkTheme(),
      themeMode: themeMode,
      home: const WebKeyboardFix(child: AuthGate()),
      debugShowCheckedModeBanner: false,
    );
  }
}

