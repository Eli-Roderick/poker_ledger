import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../data/group_providers.dart';
import '../domain/group_models.dart';

class GroupDetailScreen extends ConsumerStatefulWidget {
  final Group group;

  const GroupDetailScreen({super.key, required this.group});

  @override
  ConsumerState<GroupDetailScreen> createState() => _GroupDetailScreenState();
}

class _GroupDetailScreenState extends ConsumerState<GroupDetailScreen> {
  late Group _group;

  @override
  void initState() {
    super.initState();
    _group = widget.group;
  }

  @override
  Widget build(BuildContext context) {
    final membersAsync = ref.watch(groupMembersProvider(_group.id));

    return Scaffold(
      appBar: AppBar(
        title: Text(_group.name),
        actions: [
          if (_group.isOwner)
            PopupMenuButton<String>(
              onSelected: (value) => _handleMenuAction(value),
              itemBuilder: (context) => [
                const PopupMenuItem(
                  value: 'rename',
                  child: ListTile(
                    leading: Icon(Icons.edit),
                    title: Text('Rename Group'),
                    contentPadding: EdgeInsets.zero,
                  ),
                ),
                const PopupMenuItem(
                  value: 'delete',
                  child: ListTile(
                    leading: Icon(Icons.delete, color: Colors.red),
                    title: Text('Delete Group', style: TextStyle(color: Colors.red)),
                    contentPadding: EdgeInsets.zero,
                  ),
                ),
              ],
            ),
        ],
      ),
      body: membersAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, st) => Center(child: Text('Error: $e')),
        data: (members) => _buildMembersList(members),
      ),
      floatingActionButton: _group.isOwner
          ? FloatingActionButton.extended(
              onPressed: () => _showInviteDialog(),
              icon: const Icon(Icons.person_add),
              label: const Text('Invite'),
            )
          : null,
      bottomNavigationBar: !_group.isOwner
          ? SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: OutlinedButton(
                  onPressed: () => _leaveGroup(),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.red,
                    side: const BorderSide(color: Colors.red),
                  ),
                  child: const Text('Leave Group'),
                ),
              ),
            )
          : null,
    );
  }

  Widget _buildMembersList(List<GroupMember> members) {
    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: members.length,
      itemBuilder: (context, index) {
        final member = members[index];
        return ListTile(
          leading: CircleAvatar(
            backgroundColor: member.isOwner
                ? Theme.of(context).colorScheme.primaryContainer
                : Colors.grey.shade200,
            child: Icon(
              Icons.person,
              color: member.isOwner
                  ? Theme.of(context).colorScheme.primary
                  : Colors.grey,
            ),
          ),
          title: Row(
            children: [
              Expanded(
                child: Text(member.displayName ?? member.email ?? 'Unknown'),
              ),
              if (member.isOwner)
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
            ],
          ),
          subtitle: member.email != null && member.displayName != null
              ? Text(member.email!)
              : null,
          trailing: _group.isOwner && !member.isOwner
              ? PopupMenuButton<String>(
                  onSelected: (value) => _handleMemberAction(value, member),
                  itemBuilder: (context) => [
                    const PopupMenuItem(
                      value: 'transfer',
                      child: ListTile(
                        leading: Icon(Icons.swap_horiz),
                        title: Text('Transfer Ownership'),
                        contentPadding: EdgeInsets.zero,
                      ),
                    ),
                    const PopupMenuItem(
                      value: 'remove',
                      child: ListTile(
                        leading: Icon(Icons.remove_circle, color: Colors.red),
                        title: Text('Remove', style: TextStyle(color: Colors.red)),
                        contentPadding: EdgeInsets.zero,
                      ),
                    ),
                  ],
                )
              : null,
        );
      },
    );
  }

  Future<void> _handleMenuAction(String action) async {
    final repo = ref.read(groupRepositoryProvider);

    if (action == 'rename') {
      final nameController = TextEditingController(text: _group.name);
      final result = await showDialog<String>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Rename Group'),
          content: TextField(
            controller: nameController,
            autofocus: true,
            decoration: const InputDecoration(labelText: 'Group Name'),
            textCapitalization: TextCapitalization.words,
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
              child: const Text('Save'),
            ),
          ],
        ),
      );

      if (result != null && result.isNotEmpty) {
        await repo.updateGroupName(_group.id, result);
        setState(() {
          _group = _group.copyWith(name: result);
        });
      }
    } else if (action == 'delete') {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Delete Group'),
          content: Text('Are you sure you want to delete "${_group.name}"? This cannot be undone.'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              style: FilledButton.styleFrom(backgroundColor: Colors.red),
              child: const Text('Delete'),
            ),
          ],
        ),
      );

      if (confirmed == true) {
        await repo.deleteGroup(_group.id);
        if (mounted) {
          Navigator.pop(context);
        }
      }
    }
  }

  Future<void> _handleMemberAction(String action, GroupMember member) async {
    final repo = ref.read(groupRepositoryProvider);

    if (action == 'transfer') {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Transfer Ownership'),
          content: Text(
            'Are you sure you want to transfer ownership to ${member.displayName ?? member.email}? You will become a regular member.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Transfer'),
            ),
          ],
        ),
      );

      if (confirmed == true) {
        await repo.transferOwnership(_group.id, member.oderId);
        setState(() {
          _group = _group.copyWith(isOwner: false);
        });
        ref.invalidate(groupMembersProvider(_group.id));
      }
    } else if (action == 'remove') {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Remove Member'),
          content: Text(
            'Are you sure you want to remove ${member.displayName ?? member.email} from the group?',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              style: FilledButton.styleFrom(backgroundColor: Colors.red),
              child: const Text('Remove'),
            ),
          ],
        ),
      );

      if (confirmed == true) {
        await repo.removeMember(_group.id, member.oderId);
        ref.invalidate(groupMembersProvider(_group.id));
      }
    }
  }

  Future<void> _showInviteDialog() async {
    final emailController = TextEditingController();
    String? errorText;

    final result = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Invite Member'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: emailController,
                autofocus: true,
                decoration: InputDecoration(
                  labelText: 'Email Address',
                  hintText: 'friend@example.com',
                  errorText: errorText,
                ),
                keyboardType: TextInputType.emailAddress,
              ),
              const SizedBox(height: 8),
              Text(
                'Enter the email address the user signed up with',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Colors.grey,
                    ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () async {
                final email = emailController.text.trim();
                if (email.isEmpty) {
                  setDialogState(() => errorText = 'Please enter an email');
                  return;
                }

                final repo = ref.read(groupRepositoryProvider);
                final success = await repo.inviteMemberByEmail(_group.id, email);

                if (success) {
                  Navigator.pop(context, true);
                } else {
                  setDialogState(() => errorText = 'No user found with that email');
                }
              },
              child: const Text('Invite'),
            ),
          ],
        ),
      ),
    );

    if (result == true) {
      ref.invalidate(groupMembersProvider(_group.id));
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Member invited successfully')),
        );
      }
    }
  }

  Future<void> _leaveGroup() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Leave Group'),
        content: Text('Are you sure you want to leave "${_group.name}"?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            child: const Text('Leave'),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      final repo = ref.read(groupRepositoryProvider);
      await repo.leaveGroup(_group.id);
      if (mounted) {
        Navigator.pop(context);
      }
    }
  }
}
