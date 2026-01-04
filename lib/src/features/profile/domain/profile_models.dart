/// Represents a follow relationship between users.
/// 
/// Following allows users to see each other's complete poker history.
/// The follow system uses a request/accept model:
/// 1. User A sends a follow request to User B (status: pending)
/// 2. User B can accept (status: accepted) or reject (status: rejected)
/// 3. Once accepted, User A can see all of User B's sessions
class Follow {
  final int id;
  
  /// The user who initiated the follow request
  final String followerId;
  
  /// The user being followed
  final String followingId;
  
  /// Current status of the follow request
  final FollowStatus status;
  final DateTime createdAt;
  final DateTime updatedAt;
  
  /// Display name of the follower (for UI)
  final String? followerName;
  
  /// Display name of the user being followed (for UI)
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

/// Aggregated statistics for a user's poker performance.
/// 
/// Calculated from sessions accessible to the viewing user.
/// Stats are scoped based on ownership, group membership, and follow status.
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
