import 'package:flutter_test/flutter_test.dart';
import 'package:poker_ledger/src/utils/money.dart';

void main() {
  group('Money.tryParseCents', () {
    test('parses whole and fractional amounts exactly', () {
      expect(Money.tryParseCents('20'), 2000);
      expect(Money.tryParseCents('20.5'), 2050);
      expect(Money.tryParseCents(r'$20.05'), 2005);
      expect(Money.tryParseCents('0.01'), 1);
    });

    test('supports decimal comma and thousands separators', () {
      expect(Money.tryParseCents('20,50'), 2050);
      expect(Money.tryParseCents('1,234'), 123400);
      expect(Money.tryParseCents('1,234.56'), 123456);
      expect(Money.tryParseCents('1.234,56'), 123456);
    });

    test('rejects malformed precision and negative values by default', () {
      expect(Money.tryParseCents(''), isNull);
      expect(Money.tryParseCents('1.2345'), isNull);
      expect(Money.tryParseCents('-1.00'), isNull);
      expect(Money.tryParseCents('-1.00', allowNegative: true), -100);
    });
  });
}
