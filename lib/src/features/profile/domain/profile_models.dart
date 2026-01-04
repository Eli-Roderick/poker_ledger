/// Represents a follow relationship between users
class Follow {
  final int id;
  final String followerId;
  final String followingId;
  final FollowStatus status;
  final DateTime createdAt;
  final DateTime updatedAt;
  final String? followerName;
  final String? followingName;

  const Follow({
    required this.id,
    required this.followerId,
    required this.followingId,
    required this.status,
    required this.createdAt,
    required this.updatedAt,
    this.followerName,
    this.followingName,
  });

  factory Follow.fromMap(Map<String, dynamic> map) => Follow(
        id: map['id'] as int,
        followerId: map['follower_id'] as String,
        followingId: map['following_id'] as String,
        status: FollowStatus.fromString(map['status'] as String),
        createdAt: DateTime.parse(map['created_at'] as String),
        updatedAt: DateTime.parse(map['updated_at'] as String),
        followerName: map['follower_name'] as String?,
        followingName: map['following_name'] as String?,
      );
}

enum FollowStatus {
  pending,
  accepted,
  rejected;

  static FollowStatus fromString(String value) {
    switch (value) {
      case 'pending':
        return FollowStatus.pending;
      case 'accepted':
        return FollowStatus.accepted;
      case 'rejected':
        return FollowStatus.rejected;
      default:
        return FollowStatus.pending;
    }
  }

  String toJson() => name;
}

/// Stats for a user in shared sessions
class UserProfileStats {
  final String userId;
  final String? displayName;
  final String? email;
  final int totalSessions;
  final int totalBuyInsCents;
  final int totalCashOutsCents;
  final int netProfitCents;
  final double winRate; // percentage of sessions with positive outcome
  final int biggestWinCents;
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

/// A session where the viewed user participated
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
