import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../domain/group_models.dart';
import 'group_repository.dart';

final groupRepositoryProvider = Provider<GroupRepository>((ref) => GroupRepository());

final myGroupsProvider = FutureProvider<List<Group>>((ref) async {
  final repo = ref.read(groupRepositoryProvider);
  return repo.getMyGroups();
});

final groupMembersProvider = FutureProvider.family<List<GroupMember>, int>((ref, groupId) async {
  final repo = ref.read(groupRepositoryProvider);
  return repo.getGroupMembers(groupId);
});

final sessionGroupIdsProvider = FutureProvider.family<List<int>, int>((ref, sessionId) async {
  final repo = ref.read(groupRepositoryProvider);
  return repo.getSessionGroupIds(sessionId);
});
