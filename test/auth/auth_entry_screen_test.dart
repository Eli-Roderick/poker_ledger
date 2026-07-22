import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:poker_ledger/src/auth/presentation/auth_entry_mode.dart';
import 'package:poker_ledger/src/auth/presentation/auth_entry_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<void> pumpEntry(
    WidgetTester tester, {
    AuthEntryMode? initialMode,
    Future<AuthEntryMode> Function()? loadPreferredMode,
    Size surfaceSize = const Size(400, 1200),
  }) async {
    await tester.binding.setSurfaceSize(surfaceSize);
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: AuthEntryScreen(
            initialMode: initialMode,
            loadPreferredMode: loadPreferredMode,
            persistMode: (_) async {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('shows both Sign in and Create account segments above the fold', (
    tester,
  ) async {
    await pumpEntry(
      tester,
      initialMode: AuthEntryMode.createAccount,
      surfaceSize: const Size(360, 640),
    );

    expect(find.byType(SegmentedButton<AuthEntryMode>), findsOneWidget);
    expect(find.byTooltip('Sign in'), findsOneWidget);
    expect(find.byTooltip('Create account'), findsOneWidget);
    expect(find.text('Poker Ledger'), findsOneWidget);

    final segmentTop = tester
        .getTopLeft(find.byType(SegmentedButton<AuthEntryMode>))
        .dy;
    expect(segmentTop, lessThan(420));
  });

  testWidgets('defaults to Create account on first run', (tester) async {
    SharedPreferences.setMockInitialValues({});

    await pumpEntry(tester, loadPreferredMode: loadPreferredAuthEntryMode);

    expect(find.text('Confirm password'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Create account'), findsOneWidget);
    expect(find.text('Forgot password?'), findsNothing);
  });

  testWidgets('restores Sign in when preference was persisted', (tester) async {
    SharedPreferences.setMockInitialValues({
      authEntryModePreferenceKey: 'signIn',
    });

    await pumpEntry(tester, loadPreferredMode: loadPreferredAuthEntryMode);

    expect(find.text('Forgot password?'), findsOneWidget);
    expect(find.text('Confirm password'), findsNothing);
    expect(find.widgetWithText(FilledButton, 'Sign in'), findsOneWidget);
  });

  testWidgets('switching segments reveals the matching form', (tester) async {
    await pumpEntry(tester, initialMode: AuthEntryMode.createAccount);

    expect(find.text('Confirm password'), findsOneWidget);

    await tester.tap(find.byTooltip('Sign in'));
    await tester.pumpAndSettle();

    expect(find.text('Forgot password?'), findsOneWidget);
    expect(find.text('Confirm password'), findsNothing);
    expect(find.widgetWithText(FilledButton, 'Sign in'), findsOneWidget);

    await tester.tap(find.byTooltip('Create account'));
    await tester.pumpAndSettle();

    expect(find.text('Confirm password'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Create account'), findsOneWidget);
    expect(find.text('Forgot password?'), findsNothing);
  });

  testWidgets('footer switches mode without leaving the entry screen', (
    tester,
  ) async {
    await pumpEntry(tester, initialMode: AuthEntryMode.signIn);

    await tester.ensureVisible(find.text('New here? Create account'));
    await tester.tap(find.text('New here? Create account'));
    await tester.pumpAndSettle();

    expect(find.text('Confirm password'), findsOneWidget);

    await tester.ensureVisible(find.text('Already have an account? Sign in'));
    await tester.tap(find.text('Already have an account? Sign in'));
    await tester.pumpAndSettle();

    expect(find.text('Forgot password?'), findsOneWidget);
  });
}
