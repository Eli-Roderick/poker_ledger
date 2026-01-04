import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../auth/providers/auth_providers.dart';
import '../domain/profile_models.dart';
import 'profile_repository.dart';

final profileRepositoryProvider = Provider<ProfileRepository>((ref) {
  return ProfileRepository();
});

/// Provider for user profile stats
final userProfileStatsProvider = FutureProvider.family<UserProfileStats, UserProfileParams>((ref, params) async {
  final user = ref.watch(currentUserProvider);
  if (user == null) {
    return UserProfileStats(
      userId: params.userId,
      totalSessions: 0,
      totalBuyInsCents: 0,
      totalCashOutsCents: 0,
      netProfitCents: 0,
      winRate: 0,
      biggestWinCents: 0,
      biggestLossCents: 0,
    );
  }
  
  final repo = ref.read(profileRepositoryProvider);
  return repo.getUserStats(params.userId, groupId: params.groupId, includeFollowedStats: true);
});

/// Provider for user sessions
final userSessionsProvider = FutureProvider.family<List<UserSessionSummary>, UserProfileParams>((ref, params) async {
  final user = ref.watch(currentUserProvider);
  if (user == null) return [];
  
  final repo = ref.read(profileRepositoryProvider);
  return repo.getUserSessions(params.userId, groupId: params.groupId);
});

/// Provider for follow status with a user
final followStatusProvider = FutureProvider.family<Follow?, String>((ref, targetUserId) async {
  final user = ref.watch(currentUserProvider);
  if (user == null) return null;
  
  final repo = ref.read(profileRepositoryProvider);
  return repo.getFollowStatus(targetUserId);
});

/// Provider for pending follow requests
final pendingFollowRequestsProvider = FutureProvider<List<Follow>>((ref) async {
  final user = ref.watch(currentUserProvider);
  if (user == null) return [];
  
  final repo = ref.read(profileRepositoryProvider);
  return repo.getPendingFollowRequests();
});

/// Provider for users current user is following
final followingListProvider = FutureProvider<List<Follow>>((ref) async {
  final user = ref.watch(currentUserProvider);
  if (user == null) return [];
  
  final repo = ref.read(profileRepositoryProvider);
  return repo.getFollowing();
});

/// Provider for users following current user
final followersListProvider = FutureProvider<List<Follow>>((ref) async {
  final user = ref.watch(currentUserProvider);
  if (user == null) return [];
  
  final repo = ref.read(profileRepositoryProvider);
  return repo.getFollowers();
});

/// Provider for accessible groups (for filtering)
final accessibleGroupsProvider = FutureProvider<List<Map<String, dynamic>>>((ref) async {
  final user = ref.watch(currentUserProvider);
  if (user == null) return [];
  
  final repo = ref.read(profileRepositoryProvider);
  return repo.getAccessibleGroups();
});

/// Provider for all nicknames
final nicknamesProvider = FutureProvider<Map<int, String>>((ref) async {
  final user = ref.watch(currentUserProvider);
  if (user == null) return {};
  
  final repo = ref.read(profileRepositoryProvider);
  return repo.getAllNicknames();
});

/// Parameters for user profile queries
class UserProfileParams {
  final String userId;
  final int? groupId;

  const UserProfileParams({required this.userId, this.groupId});

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is UserProfileParams &&
          runtimeType == other.runtimeType &&
          userId == other.userId &&
          groupId == other.groupId;

  @override
  int get hashCode => userId.hashCode ^ groupId.hashCode;
}
