import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'src/auth/presentation/auth_gate.dart';
import 'src/theme/app_theme.dart';

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

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      // Dismiss keyboard when tapping outside of text fields
      onTap: () {
        FocusManager.instance.primaryFocus?.unfocus();
      },
      child: MaterialApp(
        title: 'Poker Ledger',
        theme: AppTheme.theme(),
        home: const AuthGate(),
        debugShowCheckedModeBanner: false,
        builder: (context, child) {
          // Wrap with a colored container to prevent white background
          return Container(
            color: const Color(0xFF111315),
            child: child,
          );
        },
      ),
    );
  }
}

