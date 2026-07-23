import 'package:flutter_test/flutter_test.dart';
import 'package:poker_ledger/src/config/app_links.dart';
import 'package:poker_ledger/src/routing/pending_deep_link.dart';

void main() {
  test('HTTPS inviteCode query is recognized and extracted', () {
    final uri = Uri.parse(
      'https://eli-roderick.github.io/poker_ledger/?inviteCode=zdtfaa',
    );
    expect(isPokerLedgerDeepLink(uri), isTrue);
    expect(joinCodeFromDeepLink(uri), 'ZDTFAA');
  });

  test('custom-scheme join path still extracts the code', () {
    final uri = Uri.parse('io.supabase.pokerledger://join/ABC123');
    expect(isPokerLedgerDeepLink(uri), isTrue);
    expect(joinCodeFromDeepLink(uri), 'ABC123');
  });

  test('invite URL builder uses public web base and inviteCode', () {
    expect(
      pokerLedgerInviteUrl('ab12cd'),
      'https://eli-roderick.github.io/poker_ledger/?inviteCode=AB12CD',
    );
  });
}
