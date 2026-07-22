import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../data/group_providers.dart';
import '../domain/group_models.dart';
import 'package:poker_ledger/src/features/help/presentation/help_screen.dart';
import 'group_detail_screen.dart';

class GroupsScreen extends ConsumerWidget {
  const GroupsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final groupsAsync = ref.watch(myGroupsProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Groups'),
        leading: IconButton(
          icon: const Icon(Icons.help_outline),
          onPressed: () => context.showHelp(HelpPage.groups),
          tooltip: 'Help',
        ),
        actions: [
          IconButton(
            tooltip: 'Group invitations',
            onPressed: () => _showInvitations(context, ref),
            icon: const Icon(Icons.mail_outline),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () async => ref.invalidate(myGroupsProvider),
        child: groupsAsync.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (_, __) =>
              const Center(child: Text('Groups could not be loaded.')),
          data: (groups) {
            if (groups.isEmpty) {
              return ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                children: [
                  SizedBox(height: MediaQuery.of(context).size.height * 0.25),
                  Icon(
                    Icons.group_outlined,
                    size: 80,
                    color: Colors.grey.shade400,
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'No Groups Yet',
                    style: Theme.of(context).textTheme.titleLarge,
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 8),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 32),
                    child: Text(
                      'Attach a new game to one group so every current member '
                      'can see its full ledger and standings.',
                      style: Theme.of(
                        context,
                      ).textTheme.bodyMedium?.copyWith(color: Colors.grey),
                      textAlign: TextAlign.center,
                    ),
                  ),
                ],
              );
            }

            return ListView.builder(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.symmetric(vertical: 8),
              itemCount: groups.length,
              itemBuilder: (context, index) {
                final group = groups[index];
                return _GroupTile(group: group);
              },
            );
          },
        ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        heroTag: 'groups-create-group-fab',
        tooltip: 'Create a group for games and standings',
        onPressed: () => _showCreateGroupDialog(context, ref),
        icon: const Icon(Icons.add),
        label: const Text('Create Group'),
      ),
    );
  }

  Future<void> _showCreateGroupDialog(
    BuildContext context,
    WidgetRef ref,
  ) async {
    final nameController = TextEditingController();

    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Create Group'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: nameController,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: 'Group Name',
                hintText: 'e.g., College Friends',
              ),
              textCapitalization: TextCapitalization.words,
            ),
            const SizedBox(height: 12),
            Text(
              'After creating, you can invite members by searching for their account.',
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: Colors.grey),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              final name = nameController.text.trim();
              if (name.isNotEmpty) {
                Navigator.pop(context, name);
              }
            },
            child: const Text('Create'),
          ),
        ],
      ),
    );

    if (result != null && result.isNotEmpty) {
      final repo = ref.read(groupRepositoryProvider);
      await repo.createGroup(result);
      ref.invalidate(myGroupsProvider);
    }
  }

  Future<void> _showInvitations(BuildContext context, WidgetRef ref) async {
    ref.invalidate(pendingGroupInvitationsProvider);
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => Consumer(
        builder: (modalContext, ref, _) {
          final invitations = ref.watch(pendingGroupInvitationsProvider);
          return SafeArea(
            child: SizedBox(
              height: 320,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                child: invitations.when(
                  loading: () =>
                      const Center(child: CircularProgressIndicator()),
                  error: (_, __) => const Center(
                    child: Text('Invitations could not be loaded.'),
                  ),
                  data: (items) => Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        'Group invitations',
                        style: Theme.of(modalContext).textTheme.headlineSmall,
                      ),
                      const SizedBox(height: 12),
                      if (items.isEmpty)
                        const Expanded(
                          child: Center(child: Text('No pending invitations.')),
                        )
                      else
                        Expanded(
                          child: ListView.builder(
                            itemCount: items.length,
                            itemBuilder: (_, index) {
                              final invitation = items[index];
                              return Card(
                                child: ListTile(
                                  leading: const CircleAvatar(
                                    child: Icon(Icons.group),
                                  ),
                                  title: Text(invitation.groupName),
                                  subtitle: const Text(
                                    'By joining, you and every current member '
                                    'can see complete player-level ledgers and '
                                    'standings, including games from before '
                                    'you joined.',
                                  ),
                                  trailing: Wrap(
                                    children: [
                                      IconButton(
                                        tooltip: 'Decline',
                                        onPressed: () async {
                                          await ref
                                              .read(groupRepositoryProvider)
                                              .respondToInvitation(
                                                invitation.id,
                                                accept: false,
                                              );
                                          ref.invalidate(
                                            pendingGroupInvitationsProvider,
                                          );
                                        },
                                        icon: const Icon(Icons.close),
                                      ),
                                      IconButton(
                                        tooltip: 'Accept',
                                        onPressed: () async {
                                          await ref
                                              .read(groupRepositoryProvider)
                                              .respondToInvitation(
                                                invitation.id,
                                                accept: true,
                                              );
                                          ref.invalidate(
                                            pendingGroupInvitationsProvider,
                                          );
                                          ref.invalidate(myGroupsProvider);
                                        },
                                        icon: const Icon(Icons.check),
                                      ),
                                    ],
                                  ),
                                ),
                              );
                            },
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

class _GroupTile extends ConsumerWidget {
  final Group group;

  const _GroupTile({required this.group});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: Theme.of(context).colorScheme.primaryContainer,
          child: Icon(
            Icons.group,
            color: Theme.of(context).colorScheme.primary,
          ),
        ),
        title: Row(
          children: [
            Expanded(child: Text(group.name)),
            if (group.isOwner)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.primaryContainer,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  'Owner',
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: Theme.of(context).colorScheme.primary,
                  ),
                ),
              ),
            if (group.archivedAt != null)
              const Padding(
                padding: EdgeInsets.only(left: 8),
                child: Chip(label: Text('Archived')),
              ),
          ],
        ),
        subtitle: Text(
          '${group.memberCount} member${group.memberCount == 1 ? '' : 's'}',
        ),
        trailing: const Icon(Icons.chevron_right),
        onTap: () {
          Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => GroupDetailScreen(group: group)),
          ).then((_) => ref.invalidate(myGroupsProvider));
        },
      ),
    );
  }
}
