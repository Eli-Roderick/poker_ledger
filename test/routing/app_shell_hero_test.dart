import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:poker_ledger/src/routing/app_shell.dart';

void main() {
  testWidgets('inactive tab heroes do not collide during navigation', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => buildTabStack(
            selectedIndex: 0,
            screens: [
              Scaffold(
                body: Center(
                  child: FilledButton(
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => const Scaffold(
                          body: Center(child: Text('Settings')),
                        ),
                      ),
                    ),
                    child: const Text('Open settings'),
                  ),
                ),
                floatingActionButton: FloatingActionButton(
                  onPressed: () {},
                  child: const Icon(Icons.add),
                ),
              ),
              Scaffold(
                floatingActionButton: FloatingActionButton(
                  onPressed: () {},
                  child: const Icon(Icons.group_add),
                ),
              ),
            ],
          ),
        ),
      ),
    );

    await tester.tap(find.text('Open settings'));
    await tester.pumpAndSettle();

    expect(find.text('Settings'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
