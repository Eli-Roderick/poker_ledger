import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'src/auth/presentation/auth_gate.dart';
import 'src/theme/app_theme.dart';
import 'src/utils/web_keyboard_fix.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  
  // Set system UI colors to match app theme
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    systemNavigationBarColor: Color(0xFF111315),
    systemNavigationBarDividerColor: Color(0xFF111315),
    statusBarColor: Colors.transparent,
  ));
  
  await Supabase.initialize(
    url: 'https://rgalzgiizhtwzwkfasoc.supabase.co',
    anonKey: 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InJnYWx6Z2lpemh0d3p3a2Zhc29jIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NjcxNTExMzEsImV4cCI6MjA4MjcyNzEzMX0.mhwELAeFPVT7oOdUU7KipFSxJFrTNocb9-98PWjxHsc',
  );
  
  runApp(const ProviderScope(child: MyApp()));
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  // Cache theme to avoid rebuilding on every frame
  static final _theme = AppTheme.theme();

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Poker Ledger',
      theme: _theme,
      home: const WebKeyboardFix(child: AuthGate()),
      debugShowCheckedModeBanner: false,
    );
  }
}

