import 'package:intl/intl.dart';

/// Integer-cent money helpers shared by every financial input and output.
abstract final class Money {
  static int? tryParseCents(String input, {bool allowNegative = false}) {
    var value = input.trim();
    if (value.isEmpty) return null;

    final negative = value.startsWith('-');
    if (negative && !allowNegative) return null;
    value = value.replaceAll(RegExp(r'[^0-9,.]'), '');
    if (value.isEmpty) return null;

    final lastDot = value.lastIndexOf('.');
    final lastComma = value.lastIndexOf(',');
    var decimalIndex = lastDot > lastComma ? lastDot : lastComma;
    final hasBothSeparators = lastDot != -1 && lastComma != -1;
    if (!hasBothSeparators && decimalIndex != -1) {
      final separator = value[decimalIndex];
      final separatorCount = RegExp(
        RegExp.escape(separator),
      ).allMatches(value).length;
      final digitsAfter = value.length - decimalIndex - 1;
      if (digitsAfter == 3 && separatorCount >= 1) {
        decimalIndex = -1;
      }
    }

    String whole;
    String fraction;
    if (decimalIndex == -1) {
      whole = value.replaceAll(RegExp(r'[^0-9]'), '');
      fraction = '';
    } else {
      whole = value
          .substring(0, decimalIndex)
          .replaceAll(RegExp(r'[^0-9]'), '');
      fraction = value
          .substring(decimalIndex + 1)
          .replaceAll(RegExp(r'[^0-9]'), '');
      if (fraction.length > 2) return null;
    }

    if (whole.isEmpty) whole = '0';
    final major = int.tryParse(whole);
    if (major == null) return null;
    final minor = fraction.isEmpty ? 0 : int.parse(fraction.padRight(2, '0'));
    final cents = major * 100 + minor;
    return negative ? -cents : cents;
  }

  static int parseCents(String input, {bool allowNegative = false}) {
    final cents = tryParseCents(input, allowNegative: allowNegative);
    if (cents == null) {
      throw const FormatException('Enter a valid monetary amount.');
    }
    return cents;
  }

  static String formatCents(int cents, {String? symbol, String? locale}) {
    final formatter = NumberFormat.currency(
      locale: locale,
      symbol: symbol,
      decimalDigits: 2,
    );
    return formatter.format(cents / 100);
  }
}
