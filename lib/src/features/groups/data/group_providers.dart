import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../auth/providers/auth_providers.dart';
import '../domain/group_models.dart';
import '../../session/domain/session_models.dart';
import 'group_repository.dart';

final groupRepositoryProvider = Provider<GroupRepository>(
  (ref) => GroupRepository(),
);

final myGroupsProvider = FutureProvider<List<Group>>((ref) async {
  // Watch auth state to auto-refresh when user changes
  final user = ref.watch(currentUserProvider);
  if (user == null) return [];

  final repo = ref.read(groupRepositoryProvider);
  return repo.getMyGroups();
});

final pendingGroupInvitationsProvider = FutureProvider<List<GroupInvitation>>((
  ref,
) async {
  final user = ref.watch(currentUserProvider);
  if (user == null) return [];
  return ref.read(groupRepositoryProvider).getPendingInvitations();
});

final groupMembersProvider = FutureProvider.family<List<GroupMember>, int>((
  ref,
  groupId,
) async {
  // Watch auth state to auto-refresh when user changes
  final user = ref.watch(currentUserProvider);
  if (user == null) return [];

  final repo = ref.read(groupRepositoryProvider);
  return repo.getGroupMembers(groupId);
});

final groupSessionsProvider = FutureProvider.family<List<Session>, int>((
  ref,
  groupId,
) async {
  final user = ref.watch(currentUserProvider);
  if (user == null) return [];
  return ref.read(groupRepositoryProvider).getGroupSessions(groupId);
});

class GroupStanding {
  final String name;
  final int games;
  final int netCents;

  const GroupStanding({
    required this.name,
    required this.games,
    required this.netCents,
  });
}

final groupStandingsProvider = FutureProvider.family<List<GroupStanding>, int>((
  ref,
  groupId,
) async {
  final rows = await ref.read(groupRepositoryProvider).getGroupStats(groupId);
  final totals = <String, ({String name, Set<int> games, int net})>{};
  for (final row in rows) {
    final profileId = row['profile_id'] as String?;
    final participantId = row['participant_id'] as int;
    final key = profileId ?? 'legacy:$participantId';
    final current =
        totals[key] ??
        (
          name: row['display_name_snapshot'] as String? ?? 'Deleted player',
          games: <int>{},
          net: 0,
        );
    totals[key] = (
      name: current.name,
      games: {...current.games, row['session_id'] as int},
      net: current.net + (row['net_cents'] as int),
    );
  }
  final standings =
      totals.values
          .map(
            (row) => GroupStanding(
              name: row.name,
              games: row.games.length,
              netCents: row.net,
            ),
          )
          .toList()
        ..sort((a, b) => b.netCents.compareTo(a.netCents));
  return standings;
});
