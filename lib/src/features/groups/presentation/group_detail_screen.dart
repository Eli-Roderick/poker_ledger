import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart' hide Session;
import 'package:poker_ledger/src/features/groups/data/group_providers.dart';
import 'package:poker_ledger/src/features/groups/domain/group_models.dart';
import 'package:poker_ledger/src/features/help/presentation/help_screen.dart';
import '../../session/data/v2_game_providers.dart';
import '../../session/domain/v2_game_models.dart';
import '../../session/domain/session_models.dart';
import '../../session/presentation/session_summary_screen.dart';
import '../../session/presentation/v2_game_flow_screen.dart';
import '../../../utils/money.dart';

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
    final sessionsAsync = ref.watch(groupSessionsProvider(_group.id));
    final standingsAsync = ref.watch(groupStandingsProvider(_group.id));

    return DefaultTabController(
      length: 3,
      child: Scaffold(
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
                  if (_group.archivedAt == null)
                    const PopupMenuItem(
                      value: 'rename',
                      child: ListTile(
                        leading: Icon(Icons.edit),
                        title: Text('Rename Group'),
                        contentPadding: EdgeInsets.zero,
                      ),
                    ),
                  const PopupMenuItem(
                    value: 'transfer',
                    child: ListTile(
                      leading: Icon(Icons.manage_accounts_outlined),
                      title: Text('Transfer Ownership'),
                      contentPadding: EdgeInsets.zero,
                    ),
                  ),
                  if (_group.archivedAt == null)
                    const PopupMenuItem(
                      value: 'delete',
                      child: ListTile(
                        leading: Icon(Icons.archive_outlined),
                        title: Text('Archive Group'),
                        contentPadding: EdgeInsets.zero,
                      ),
                    ),
                ],
              ),
          ],
          bottom: const TabBar(
            tabs: [
              Tab(text: 'Members'),
              Tab(text: 'Games'),
              Tab(text: 'Standings'),
            ],
          ),
        ),
        body: TabBarView(
          children: [
            membersAsync.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (_, __) => const Center(
                child: Text('Group members could not be loaded.'),
              ),
              data: _buildMembersList,
            ),
            sessionsAsync.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (_, __) =>
                  const Center(child: Text('Group games could not be loaded.')),
              data: _buildGames,
            ),
            standingsAsync.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (_, __) => const Center(
                child: Text('Group standings could not be loaded.'),
              ),
              data: _buildStandings,
            ),
          ],
        ),
        floatingActionButton: _group.canManageGames && _group.archivedAt == null
            ? FloatingActionButton.extended(
                heroTag: 'group-detail-invite-fab',
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
      ),
    );
  }

  Widget _buildMembersList(List<GroupMember> members) {
    final currentUserId = Supabase.instance.client.auth.currentUser?.id;
    final showArchived = _group.archivedAt != null;

    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: members.length + (showArchived ? 1 : 0),
      itemBuilder: (context, index) {
        if (showArchived && index == 0) {
          return const Card(
            margin: EdgeInsets.fromLTRB(16, 8, 16, 16),
            child: ListTile(
              leading: Icon(Icons.archive_outlined),
              title: Text('Archived group'),
              subtitle: Text(
                'History and standings remain visible. New games, '
                'invitations, and membership changes are locked.',
              ),
            ),
          );
        }
        final member = members[index - (showArchived ? 1 : 0)];
        final isCurrentUser = member.oderId == currentUserId;

        return ListTile(
          leading: CircleAvatar(
            backgroundColor: member.isOwner
                ? Theme.of(context).colorScheme.primaryContainer
                : Theme.of(context).colorScheme.surfaceContainerHighest,
            child: Icon(
              Icons.person,
              color: member.isOwner
                  ? Theme.of(context).colorScheme.primary
                  : Theme.of(context).colorScheme.outline,
            ),
          ),
          title: Row(
            children: [
              Expanded(
                child: Text(member.displayName ?? member.handle ?? 'Unknown'),
              ),
              if (member.isOwner)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 2,
                  ),
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
              if (!member.isOwner && member.canManageGames)
                Padding(
                  padding: const EdgeInsets.only(left: 4),
                  child: Chip(
                    visualDensity: VisualDensity.compact,
                    label: const Text('Game admin'),
                  ),
                ),
              if (isCurrentUser)
                Container(
                  margin: const EdgeInsets.only(left: 4),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.secondaryContainer,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    'You',
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: Theme.of(context).colorScheme.secondary,
                    ),
                  ),
                ),
            ],
          ),
          subtitle: member.handle != null ? Text('@${member.handle}') : null,
          trailing: _buildMemberTrailing(member),
        );
      },
    );
  }

  Widget _buildGames(List<Session> sessions) {
    if (sessions.isEmpty) {
      return const Center(
        child: Text('No games are attached to this group yet.'),
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: sessions.length,
      separatorBuilder: (_, __) => const Divider(height: 1),
      itemBuilder: (context, index) {
        final game = sessions[index];
        return ListTile(
          leading: Icon(game.finalized ? Icons.lock_outline : Icons.casino),
          title: Text(
            game.name?.trim().isNotEmpty == true
                ? game.name!
                : 'Game #${game.id}',
          ),
          subtitle: Text(
            '${game.startedAt.toLocal()} · '
            '${game.finalized ? 'Finalized' : game.phase}',
          ),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => game.ledgerVersion == 2
                  ? V2GameFlowScreen(sessionId: game.id!)
                  : SessionSummaryScreen(sessionId: game.id!),
            ),
          ),
        );
      },
    );
  }

  Widget _buildStandings(List<GroupStanding> standings) {
    if (standings.isEmpty) {
      return const Center(
        child: Text('Standings appear after a group game is finalized.'),
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: standings.length,
      separatorBuilder: (_, __) => const Divider(height: 1),
      itemBuilder: (context, index) {
        final standing = standings[index];
        final isProfit = standing.netCents > 0;
        final isLoss = standing.netCents < 0;
        return ListTile(
          leading: CircleAvatar(child: Text('${index + 1}')),
          title: Text(standing.name),
          subtitle: Text(
            '${standing.games} finalized '
            'game${standing.games == 1 ? '' : 's'}',
          ),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                isProfit
                    ? Icons.trending_up
                    : isLoss
                    ? Icons.trending_down
                    : Icons.remove,
                color: isProfit
                    ? Colors.green
                    : isLoss
                    ? Theme.of(context).colorScheme.error
                    : null,
              ),
              const SizedBox(width: 6),
              Text(
                Money.formatCents(standing.netCents, symbol: '\$'),
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget? _buildMemberTrailing(GroupMember member) {
    if (_group.isOwner && _group.archivedAt == null && !member.isOwner) {
      return PopupMenuButton<String>(
        tooltip: 'Manage member',
        onSelected: (action) => _handleMemberAction(action, member),
        itemBuilder: (_) => [
          PopupMenuItem(
            value: member.canManageGames ? 'revoke_admin' : 'make_admin',
            child: Text(
              member.canManageGames
                  ? 'Remove game administrator'
                  : 'Make game administrator',
            ),
          ),
          const PopupMenuItem(value: 'remove', child: Text('Remove member')),
        ],
      );
    }
    if (_group.canManageGames && _group.archivedAt == null && !member.isOwner) {
      return IconButton(
        icon: const Icon(Icons.remove_circle, color: Colors.red),
        onPressed: () => _handleMemberAction('remove', member),
        tooltip: 'Remove member',
      );
    }

    return null;
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
    } else if (action == 'transfer') {
      await _transferOwnership();
    } else if (action == 'delete') {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Archive Group'),
          content: Text(
            'Archive "${_group.name}"? Existing games and standings stay '
            'read-only, but no new games or members can be added.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Archive'),
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

  Future<void> _transferOwnership() async {
    final members = await ref.read(groupMembersProvider(_group.id).future);
    final candidates = members.where((member) => !member.isOwner).toList();
    if (!mounted) return;
    if (candidates.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Invite and accept another member before transfer.'),
        ),
      );
      return;
    }
    final selected = await showDialog<GroupMember>(
      context: context,
      builder: (dialogContext) => SimpleDialog(
        title: const Text('Choose the new owner'),
        children: candidates
            .map(
              (member) => SimpleDialogOption(
                onPressed: () => Navigator.pop(dialogContext, member),
                child: ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(member.displayName ?? member.handle ?? 'Member'),
                  subtitle: member.handle == null
                      ? null
                      : Text('@${member.handle}'),
                ),
              ),
            )
            .toList(),
      ),
    );
    if (selected == null || !mounted) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Transfer ownership?'),
        content: Text(
          '${selected.displayName ?? selected.handle ?? 'This member'} will '
          'become the group owner. You will remain an administrator.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Transfer'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await ref
        .read(groupRepositoryProvider)
        .transferOwnership(_group.id, selected.oderId);
    ref.invalidate(myGroupsProvider);
    if (mounted) Navigator.pop(context);
  }

  Future<void> _handleMemberAction(String action, GroupMember member) async {
    final repo = ref.read(groupRepositoryProvider);

    if (action == 'remove') {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Remove Member'),
          content: Text(
            'Remove ${member.displayName ?? member.handle ?? 'this member'}? '
            'They immediately lose group-only access but keep games they played.',
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
    } else if (action == 'make_admin' || action == 'revoke_admin') {
      await repo.setMemberGameManager(
        _group.id,
        member.oderId,
        enabled: action == 'make_admin',
      );
      ref.invalidate(groupMembersProvider(_group.id));
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
  List<DiscoverableProfile> _searchResults = [];
  DiscoverableProfile? _selectedPlayer;
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
      final results = await ref
          .read(v2GameRepositoryProvider)
          .searchProfiles(query, groupId: widget.groupId);
      if (mounted) {
        setState(() {
          _searchResults = results;
          _isSearching = false;
        });
      }
    } catch (_) {
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

  void _selectPlayer(DiscoverableProfile player) {
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
    if (_selectedPlayer == null) return;

    setState(() => _isInviting = true);

    try {
      final repo = ref.read(groupRepositoryProvider);
      final success = await repo.inviteMemberByUserId(
        widget.groupId,
        _selectedPlayer!.id,
      );

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
        _errorText = 'The invitation could not be sent. Please try again.';
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
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 8,
                ),
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
                    labelText: 'Search by handle or display name',
                    hintText: 'Email addresses are never searchable',
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
                      border: Border.all(
                        color: Colors.green.withValues(alpha: 0.3),
                      ),
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
                                _selectedPlayer!.displayName,
                                style: const TextStyle(
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              Text(
                                '@${_selectedPlayer!.handle}',
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
                            backgroundColor: Theme.of(
                              context,
                            ).colorScheme.primaryContainer,
                            child: Icon(
                              Icons.person,
                              color: Theme.of(context).colorScheme.primary,
                            ),
                          ),
                          title: Text(player.displayName),
                          subtitle: Text(switch (player.resultState) {
                            'group_member' =>
                              '@${player.handle} · Already a member',
                            'group_invited' =>
                              '@${player.handle} · Invitation pending',
                            _ => '@${player.handle}',
                          }),
                          trailing: player.canInvite
                              ? const Icon(Icons.add_circle_outline)
                              : const Icon(Icons.check_circle_outline),
                          onTap: player.canInvite
                              ? () => _selectPlayer(player)
                              : null,
                        ),
                      );
                    },
                  ),
                )
              else if (_searchResults.isEmpty &&
                  _searchCtrl.text.isNotEmpty &&
                  !_isSearching &&
                  _selectedPlayer == null)
                Expanded(
                  child: Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          Icons.search_off,
                          size: 48,
                          color: Colors.grey.shade400,
                        ),
                        const SizedBox(height: 8),
                        Text(
                          'No discoverable accounts found',
                          style: TextStyle(color: Colors.grey.shade600),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'Try a unique handle or display name',
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(color: Colors.grey.shade500),
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
                        Icon(
                          Icons.person_search,
                          size: 48,
                          color: Colors.grey.shade400,
                        ),
                        const SizedBox(height: 8),
                        Text(
                          'Search Poker Ledger accounts to invite',
                          style: TextStyle(color: Colors.grey.shade600),
                        ),
                      ],
                    ),
                  ),
                ),
              // Invite button
              if (_selectedPlayer != null) const Spacer(),
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
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            )
                          : const Icon(Icons.person_add),
                      label: Text(
                        _isInviting ? 'Inviting...' : 'Invite to Group',
                      ),
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
