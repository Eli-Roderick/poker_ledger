/// Public web origin for shareable invite links (GitHub Pages deploy).
const String pokerLedgerWebBaseUrl =
    'https://eli-roderick.github.io/poker_ledger/';

/// Builds the HTTPS invite URL shown in the share sheet and QR code.
String pokerLedgerInviteUrl(String code) {
  final uri = Uri.parse(pokerLedgerWebBaseUrl).replace(
    queryParameters: {'inviteCode': code.trim().toUpperCase()},
  );
  return uri.toString();
}
