/// Aggregated statistics for a user's poker performance.
///
/// Calculated from sessions accessible to the viewing user.
/// Stats are scoped by participation and current group membership.
class UserProfileStats {
  final String userId;
  final String? displayName;
  final String? email;

  /// Total number of sessions the user participated in
  final int totalSessions;

  /// Sum of all buy-ins across sessions (in cents)
  final int totalBuyInsCents;

  /// Sum of all cash-outs across sessions (in cents)
  final int totalCashOutsCents;

  /// Net profit/loss (cash-outs - buy-ins) in cents
  final int netProfitCents;

  /// Percentage of sessions with positive outcome (0-100)
  final double winRate;

  /// Best single-session result in cents
  final int biggestWinCents;

  /// Worst single-session result in cents (negative)
  final int biggestLossCents;

  const UserProfileStats({
    required this.userId,
    this.displayName,
    this.email,
    required this.totalSessions,
    required this.totalBuyInsCents,
    required this.totalCashOutsCents,
    required this.netProfitCents,
    required this.winRate,
    required this.biggestWinCents,
    required this.biggestLossCents,
  });
}

/// Summary of a single session for display in user profile history.
///
/// Contains the key financial details and metadata for one session
/// where the viewed user participated.
class UserSessionSummary {
  final int sessionId;
  final String? sessionName;
  final DateTime startedAt;
  final bool finalized;
  final int buyInsCents;
  final int cashOutsCents;
  final int netCents;
  final String ownerName;
  final bool isOwner;
  final int? groupId;
  final String? groupName;
  final int ledgerVersion;

  const UserSessionSummary({
    required this.sessionId,
    this.sessionName,
    required this.startedAt,
    required this.finalized,
    required this.buyInsCents,
    required this.cashOutsCents,
    required this.netCents,
    required this.ownerName,
    required this.isOwner,
    this.groupId,
    this.groupName,
    required this.ledgerVersion,
  });
}

/// Nickname for a player (custom per user)
class PlayerNickname {
  final int id;
  final String userId;
  final int playerId;
  final String nickname;

  const PlayerNickname({
    required this.id,
    required this.userId,
    required this.playerId,
    required this.nickname,
  });

  factory PlayerNickname.fromMap(Map<String, dynamic> map) => PlayerNickname(
    id: map['id'] as int,
    userId: map['user_id'] as String,
    playerId: map['player_id'] as int,
    nickname: map['nickname'] as String,
  );
}
