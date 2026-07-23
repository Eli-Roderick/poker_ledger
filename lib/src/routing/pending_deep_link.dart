import 'package:flutter_riverpod/flutter_riverpod.dart';

final pendingDeepLinkProvider = StateProvider<Uri?>((ref) => null);

bool isPokerLedgerDeepLink(Uri uri) {
  if (uri.queryParameters['inviteCode']?.trim().isNotEmpty == true) {
    return true;
  }
  return uri.host == 'join' ||
      uri.host == 'game-invite' ||
      uri.host == 'group-invite' ||
      uri.pathSegments.contains('join') ||
      uri.pathSegments.contains('game-invite') ||
      uri.pathSegments.contains('group-invite');
}

String? joinCodeFromDeepLink(Uri uri) {
  final inviteCode = uri.queryParameters['inviteCode']?.trim();
  if (inviteCode != null && inviteCode.isNotEmpty) {
    return inviteCode.toUpperCase();
  }
  if (uri.host == 'join' && uri.pathSegments.isNotEmpty) {
    return uri.pathSegments.first.toUpperCase();
  }
  final index = uri.pathSegments.indexOf('join');
  if (index >= 0 && index + 1 < uri.pathSegments.length) {
    return uri.pathSegments[index + 1].toUpperCase();
  }
  return null;
}
