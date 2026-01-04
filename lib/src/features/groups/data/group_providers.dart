import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../auth/providers/auth_providers.dart';
import '../domain/group_models.dart';
import 'group_repository.dart';

final groupRepositoryProvider = Provider<GroupRepository>((ref) => GroupRepository());

final myGroupsProvider = FutureProvider<List<Group>>((ref) async {
  // Watch auth state to auto-refresh when user changes
  final user = ref.watch(currentUserProvider);
  if (user == null) return [];
  
  final repo = ref.read(groupRepositoryProvider);
  return repo.getMyGroups();
});

final groupMembersProvider = FutureProvider.family<List<GroupMember>, int>((ref, groupId) async {
  // Watch auth state to auto-refresh when user changes
  final user = ref.watch(currentUserProvider);
  if (user == null) return [];
  
  final repo = ref.read(groupRepositoryProvider);
  return repo.getGroupMembers(groupId);
});

final sessionGroupIdsProvider = FutureProvider.family<List<int>, int>((ref, sessionId) async {
  // Watch auth state to auto-refresh when user changes
  final user = ref.watch(currentUserProvider);
  if (user == null) return [];
  
  final repo = ref.read(groupRepositoryProvider);
  return repo.getSessionGroupIds(sessionId);
});
