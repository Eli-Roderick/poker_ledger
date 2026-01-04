import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:poker_ledger/src/features/groups/data/group_providers.dart';
import 'package:poker_ledger/src/features/groups/domain/group_models.dart';
import 'package:poker_ledger/src/features/help/presentation/help_screen.dart';
import '../../players/data/players_providers.dart';
import '../../players/domain/player.dart';

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
          IconButton(
            icon: const Icon(Icons.help_outline),
            onPressed: () => context.showHelp(HelpPage.groupDetail),
            tooltip: 'Help',
          ),
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
              ? IconButton(
                  icon: const Icon(Icons.remove_circle, color: Colors.red),
                  onPressed: () => _handleMemberAction('remove', member),
                  tooltip: 'Remove member',
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

    if (action == 'remove') {
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
    final result = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (sheetContext) => _InviteMemberSheet(
        groupId: _group.id,
        onInvited: () {
          ref.invalidate(groupMembersProvider(_group.id));
        },
      ),
    );

    if (result == true && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Member invited successfully')),
      );
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

class _InviteMemberSheet extends ConsumerStatefulWidget {
  final int groupId;
  final VoidCallback onInvited;

  const _InviteMemberSheet({required this.groupId, required this.onInvited});

  @override
  ConsumerState<_InviteMemberSheet> createState() => _InviteMemberSheetState();
}

class _InviteMemberSheetState extends ConsumerState<_InviteMemberSheet> {
  final _searchCtrl = TextEditingController();
  Timer? _debounce;
  bool _isSearching = false;
  List<Player> _searchResults = [];
  Player? _selectedPlayer;
  bool _isInviting = false;
  String? _errorText;

  @override
  void dispose() {
    _searchCtrl.dispose();
    _debounce?.cancel();
    super.dispose();
  }

  Future<void> _searchPlayers(String query) async {
    if (query.trim().isEmpty) {
      setState(() {
        _searchResults = [];
        _isSearching = false;
      });
      return;
    }

    setState(() => _isSearching = true);

    try {
      // Search through user's linked players, not all users
      final results = await ref.read(playersListProvider.notifier).searchLinkedPlayers(query);
      if (mounted) {
        setState(() {
          _searchResults = results;
          _isSearching = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isSearching = false);
      }
    }
  }

  void _onSearchChanged(String query) {
    _debounce?.cancel();
    setState(() => _errorText = null);
    _debounce = Timer(const Duration(milliseconds: 400), () {
      _searchPlayers(query);
    });
  }

  void _selectPlayer(Player player) {
    setState(() {
      _selectedPlayer = player;
      _searchCtrl.clear();
      _searchResults = [];
      _errorText = null;
    });
  }

  void _clearSelectedPlayer() {
    setState(() {
      _selectedPlayer = null;
    });
  }

  Future<void> _invitePlayer() async {
    if (_selectedPlayer == null || _selectedPlayer!.linkedUserId == null) return;

    setState(() => _isInviting = true);

    try {
      final repo = ref.read(groupRepositoryProvider);
      // Use the linked user ID directly
      final success = await repo.inviteMemberByUserId(widget.groupId, _selectedPlayer!.linkedUserId!);

      if (success) {
        widget.onInvited();
        if (mounted) {
          Navigator.pop(context, true);
        }
      } else {
        setState(() {
          _errorText = 'Could not invite this player';
          _isInviting = false;
        });
      }
    } catch (e) {
      setState(() {
        _errorText = 'Error inviting player: $e';
        _isInviting = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: DraggableScrollableSheet(
        initialChildSize: 0.95,
        minChildSize: 0.5,
        maxChildSize: 0.95,
        expand: false,
        builder: (context, scrollController) {
          return Column(
            children: [
              // Handle
              Container(
                margin: const EdgeInsets.only(top: 12, bottom: 8),
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.grey.shade300,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              // Title
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: Row(
                  children: [
                    Text(
                      'Invite Member',
                      style: Theme.of(context).textTheme.titleLarge?.copyWith(
                            fontWeight: FontWeight.bold,
                          ),
                    ),
                    const Spacer(),
                    IconButton(
                      icon: const Icon(Icons.close),
                      onPressed: () => Navigator.pop(context),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1),
              // Search field
              Padding(
                padding: const EdgeInsets.all(16),
                child: TextField(
                  controller: _searchCtrl,
                  autofocus: true,
                  decoration: InputDecoration(
                    labelText: 'Search by email or name',
                    hintText: 'Start typing to search users...',
                    prefixIcon: const Icon(Icons.search),
                    suffixIcon: _isSearching
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: Padding(
                              padding: EdgeInsets.all(12),
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                          )
                        : _searchCtrl.text.isNotEmpty
                            ? IconButton(
                                icon: const Icon(Icons.clear),
                                onPressed: () {
                                  _searchCtrl.clear();
                                  setState(() => _searchResults = []);
                                },
                              )
                            : null,
                    errorText: _errorText,
                  ),
                  onChanged: _onSearchChanged,
                ),
              ),
              // Selected player
              if (_selectedPlayer != null)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.green.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: Colors.green.withValues(alpha: 0.3)),
                    ),
                    child: Row(
                      children: [
                        CircleAvatar(
                          backgroundColor: Colors.green.withValues(alpha: 0.2),
                          child: const Icon(Icons.person, color: Colors.green),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                _selectedPlayer!.name,
                                style: const TextStyle(fontWeight: FontWeight.w600),
                              ),
                              if (_selectedPlayer!.email != null)
                                Text(
                                  _selectedPlayer!.email!,
                                  style: Theme.of(context).textTheme.bodySmall,
                                ),
                            ],
                          ),
                        ),
                        IconButton(
                          icon: const Icon(Icons.close),
                          onPressed: _clearSelectedPlayer,
                        ),
                      ],
                    ),
                  ),
                ),
              // Search results
              if (_searchResults.isNotEmpty && _selectedPlayer == null)
                Expanded(
                  child: ListView.builder(
                    controller: scrollController,
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    itemCount: _searchResults.length,
                    itemBuilder: (context, index) {
                      final player = _searchResults[index];
                      return Card(
                        margin: const EdgeInsets.only(bottom: 8),
                        child: ListTile(
                          leading: CircleAvatar(
                            backgroundColor: Theme.of(context).colorScheme.primaryContainer,
                            child: Icon(
                              Icons.person,
                              color: Theme.of(context).colorScheme.primary,
                            ),
                          ),
                          title: Text(player.name),
                          subtitle: Text(player.email ?? ''),
                          trailing: const Icon(Icons.add_circle_outline),
                          onTap: () => _selectPlayer(player),
                        ),
                      );
                    },
                  ),
                )
              else if (_searchResults.isEmpty && _searchCtrl.text.isNotEmpty && !_isSearching && _selectedPlayer == null)
                Expanded(
                  child: Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.search_off, size: 48, color: Colors.grey.shade400),
                        const SizedBox(height: 8),
                        Text(
                          'No linked players found',
                          style: TextStyle(color: Colors.grey.shade600),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'Search your players who have linked accounts',
                          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                color: Colors.grey.shade500,
                              ),
                        ),
                      ],
                    ),
                  ),
                )
              else if (_selectedPlayer == null)
                Expanded(
                  child: Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.person_search, size: 48, color: Colors.grey.shade400),
                        const SizedBox(height: 8),
                        Text(
                          'Search your linked players to invite',
                          style: TextStyle(color: Colors.grey.shade600),
                        ),
                      ],
                    ),
                  ),
                ),
              // Invite button
              if (_selectedPlayer != null)
                const Spacer(),
              if (_selectedPlayer != null)
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      onPressed: _isInviting ? null : _invitePlayer,
                      icon: _isInviting
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                            )
                          : const Icon(Icons.person_add),
                      label: Text(_isInviting ? 'Inviting...' : 'Invite to Group'),
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}
