import 'package:flutter/material.dart';
import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../analytics/data/analytics_providers.dart';

import 'package:poker_ledger/src/features/players/data/players_providers.dart';
import 'package:poker_ledger/src/features/help/presentation/help_screen.dart';
import 'package:poker_ledger/src/features/players/domain/player.dart';
import 'package:poker_ledger/src/features/profile/presentation/user_profile_screen.dart';

class PlayersListScreen extends ConsumerStatefulWidget {
  static const routeName = '/players';
  const PlayersListScreen({super.key});

  @override
  ConsumerState<PlayersListScreen> createState() => _PlayersListScreenState();
}

class _PlayersListScreenState extends ConsumerState<PlayersListScreen> {
  final _searchCtrl = TextEditingController();
  Timer? _debounce;

  @override
  void dispose() {
    _debounce?.cancel();
    _searchCtrl.clear(); // Clear search when leaving page
    _searchCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final playersAsync = ref.watch(playersListProvider);
    final showDeactivated = ref.read(playersListProvider.notifier).showDeactivated;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Players'),
        leading: IconButton(
          icon: const Icon(Icons.help_outline),
          onPressed: () => context.showHelp(HelpPage.players),
          tooltip: 'Help',
        ),
        actions: [
          IconButton(
            tooltip: showDeactivated ? 'Show active' : 'Show deactivated',
            icon: Icon(showDeactivated ? Icons.visibility : Icons.visibility_off),
            onPressed: () async {
              await ref.read(playersListProvider.notifier).toggleShowDeactivated();
            },
          ),
        ],
      ),
      body: playersAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, st) => Center(child: Text('Error: $e')),
        data: (players) {
          final q = _searchCtrl.text.trim().toLowerCase();
          final filtered = q.isEmpty
              ? players
              : players.where((p) {
                  final name = p.name.toLowerCase();
                  final email = (p.email ?? '').toLowerCase();
                  final phone = (p.phone ?? '').toLowerCase();
                  return name.contains(q) || email.contains(q) || phone.contains(q);
                }).toList();
          return RefreshIndicator(
            onRefresh: () => ref.read(playersListProvider.notifier).refresh(),
            child: filtered.isEmpty
                ? Column(
                    children: [
                      _SearchBar(controller: _searchCtrl, onChanged: _onQueryChanged),
                      const Expanded(child: ListEmptyState()),
                    ],
                  )
                : ListView.builder(
                    physics: const AlwaysScrollableScrollPhysics(),
                    itemCount: filtered.length + 1 + (showDeactivated ? 1 : 0),
                    itemBuilder: (context, index) {
                      if (index == 0) {
                        return _SearchBar(controller: _searchCtrl, onChanged: _onQueryChanged);
                      }
                      if (showDeactivated && index == 1) {
                        return Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 12.0, vertical: 8.0),
                          child: Row(
                            children: const [
                              Icon(Icons.info_outline, size: 18),
                              SizedBox(width: 8),
                              Expanded(child: Text('Viewing deactivated accounts')),
                            ],
                          ),
                        );
                      }
                      final offset = 1 + (showDeactivated ? 1 : 0);
                      final p = filtered[index - offset];
                      return PlayerTile(player: p);
                    },
                  ),
          );
        },
      ),
      floatingActionButton: FloatingActionButton.extended(
        tooltip: 'Add a player to your roster',
        onPressed: () async {
          final created = await showModalBottomSheet<_CreatePlayerResult?>(
            context: context,
            isScrollControlled: true,
            useSafeArea: true,
            builder: (context) => const _AddPlayerSheet(),
          );
          if (created != null && created.linkedUserId != null) {
            await ref.read(playersListProvider.notifier).addPlayer(
                  name: created.name.trim(),
                  email: created.email?.trim(),
                  linkedUserId: created.linkedUserId,
                );
            // Clear search after adding a player
            _searchCtrl.clear();
            if (mounted) setState(() {});
          }
        },
        icon: const Icon(Icons.person_add),
        label: const Text('Add Player'),
      ),
    );
  }

  void _onQueryChanged(String _) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 250), () {
      if (mounted) setState(() {});
    });
  }
}

class _SearchBar extends StatelessWidget {
  final TextEditingController controller;
  final ValueChanged<String> onChanged;
  const _SearchBar({required this.controller, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
      child: TextField(
        controller: controller,
        onChanged: onChanged,
        decoration: InputDecoration(
          prefixIcon: const Icon(Icons.search),
          hintText: 'Search players',
          isDense: true,
          suffixIcon: controller.text.isEmpty
              ? null
              : IconButton(
                  icon: const Icon(Icons.clear),
                  onPressed: () {
                    controller.clear();
                    onChanged('');
                  },
                ),
        ),
      ),
    );
  }
}

class _EditPlayerResult {
  final String name;
  final String? email;
  final String? phone;
  final String? notes;
  const _EditPlayerResult({required this.name, this.email, this.phone, this.notes});
}

class _EditPlayerDialog extends StatefulWidget {
  final Player player;
  const _EditPlayerDialog({required this.player});

  @override
  State<_EditPlayerDialog> createState() => _EditPlayerDialogState();
}

class _EditPlayerDialogState extends State<_EditPlayerDialog> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _nameCtrl;
  late final TextEditingController _emailCtrl;
  late final TextEditingController _phoneCtrl;
  late final TextEditingController _notesCtrl;

  @override
  void initState() {
    super.initState();
    _nameCtrl = TextEditingController(text: widget.player.name);
    _emailCtrl = TextEditingController(text: widget.player.email ?? '');
    _phoneCtrl = TextEditingController(text: widget.player.phone ?? '');
    _notesCtrl = TextEditingController(text: widget.player.notes ?? '');
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _emailCtrl.dispose();
    _phoneCtrl.dispose();
    _notesCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Edit Player'),
      content: Form(
        key: _formKey,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextFormField(
                controller: _nameCtrl,
                decoration: const InputDecoration(labelText: 'Name'),
                validator: (v) => (v == null || v.trim().isEmpty) ? 'Name required' : null,
              ),
              const SizedBox(height: 8),
              TextFormField(
                controller: _emailCtrl,
                decoration: const InputDecoration(labelText: 'Email (optional)'),
                keyboardType: TextInputType.emailAddress,
              ),
              const SizedBox(height: 8),
              TextFormField(
                controller: _phoneCtrl,
                decoration: const InputDecoration(labelText: 'Phone (optional)'),
                keyboardType: TextInputType.phone,
              ),
              const SizedBox(height: 8),
              TextFormField(
                controller: _notesCtrl,
                decoration: const InputDecoration(labelText: 'Notes (optional)'),
                maxLines: 2,
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(
          onPressed: () {
            if (_formKey.currentState!.validate()) {
              Navigator.pop(
                context,
                _EditPlayerResult(
                  name: _nameCtrl.text,
                  email: _emailCtrl.text.isEmpty ? null : _emailCtrl.text,
                  phone: _phoneCtrl.text.isEmpty ? null : _phoneCtrl.text,
                  notes: _notesCtrl.text.isEmpty ? null : _notesCtrl.text,
                ),
              );
            }
          },
          child: const Text('Save'),
        ),
      ],
    );
  }
}

class PlayerTile extends ConsumerWidget {
  final Player player;
  const PlayerTile({super.key, required this.player});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: player.isLinked
              ? Theme.of(context).colorScheme.primaryContainer
              : Colors.grey.shade200,
          child: Icon(
            Icons.person,
            color: player.isLinked
                ? Theme.of(context).colorScheme.primary
                : Colors.grey,
          ),
        ),
        title: Text(player.name),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Show email if available (for linked users, show their email)
            if (player.email != null && player.email!.isNotEmpty)
              Text(player.email!, style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Theme.of(context).colorScheme.outline)),
            if (player.isGuest)
              Text('Legacy guest', style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Colors.orange)),
          ],
        ),
        onTap: () {
          if (player.id == null) return;
          // Navigate to user profile if linked, otherwise show edit dialog
          if (player.isLinked && player.linkedUserId != null) {
            Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => UserProfileScreen(
                  userId: player.linkedUserId!,
                  initialDisplayName: player.linkedUserDisplayName ?? player.name,
                  playerId: player.id,
                  playerName: player.name,
                ),
              ),
            );
          } else {
            // For guest players, show edit dialog
            _showEditDialog(context, ref, player);
          }
        },
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (player.isGuest)
              IconButton(
                tooltip: 'Link to account',
                icon: const Icon(Icons.link),
                onPressed: () => _showLinkUserSheet(context, ref, player),
              ),
            if (player.active)
              IconButton(
                tooltip: 'Deactivate',
                icon: const Icon(Icons.person_off_outlined),
                onPressed: () async {
                  if (player.id == null) return;
                  final ok = await showDialog<bool>(
                    context: context,
                    builder: (_) => AlertDialog(
                      title: const Text('Deactivate player?'),
                      content: Text('This hides ${player.name} from analytics and future sessions. You can reactivate later.'),
                      actions: [
                        TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
                        FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Deactivate')),
                      ],
                    ),
                  );
                  if (ok == true) {
                    await ref.read(playersListProvider.notifier).setActive(id: player.id!, active: false);
                    await ref.read(analyticsProvider.notifier).refresh();
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('${player.name} deactivated')));
                    }
                  }
                },
              )
            else
              IconButton(
                tooltip: 'Reactivate',
                icon: const Icon(Icons.restart_alt),
                onPressed: () async {
                  if (player.id == null) return;
                  await ref.read(playersListProvider.notifier).setActive(id: player.id!, active: true);
                  await ref.read(analyticsProvider.notifier).refresh();
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('${player.name} reactivated')));
                  }
                },
              ),
          ],
        ),
      ),
    );
  }
}

Future<void> _showEditDialog(BuildContext context, WidgetRef ref, Player player) async {
  if (player.id == null) return;
  final edited = await showDialog<_EditPlayerResult?>(
    context: context,
    builder: (_) => _EditPlayerDialog(player: player),
  );
  if (edited != null) {
    await ref.read(playersListProvider.notifier).updatePlayer(
          id: player.id!,
          name: edited.name.trim(),
          email: edited.email?.trim(),
          phone: edited.phone?.trim(),
          notes: edited.notes?.trim(),
        );
  }
}

Future<void> _showLinkUserSheet(BuildContext context, WidgetRef ref, Player player) async {
  final result = await showModalBottomSheet<UserSearchResult?>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (sheetContext) => _LinkUserSheet(player: player),
  );

  if (result != null && player.id != null) {
    await ref.read(playersListProvider.notifier).linkPlayerToUser(
          playerId: player.id!,
          userId: result.id,
        );
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${player.name} linked to ${result.displayName ?? result.email}')),
      );
    }
  }
}

class _LinkUserSheet extends ConsumerStatefulWidget {
  final Player player;
  const _LinkUserSheet({required this.player});

  @override
  ConsumerState<_LinkUserSheet> createState() => _LinkUserSheetState();
}

class _LinkUserSheetState extends ConsumerState<_LinkUserSheet> {
  final _searchCtrl = TextEditingController();
  Timer? _debounce;
  bool _isSearching = false;
  List<UserSearchResult> _searchResults = [];
  UserSearchResult? _selectedUser;

  @override
  void dispose() {
    _searchCtrl.dispose();
    _debounce?.cancel();
    super.dispose();
  }

  Future<void> _searchUsers(String query) async {
    if (query.trim().isEmpty) {
      setState(() {
        _searchResults = [];
        _isSearching = false;
      });
      return;
    }

    setState(() => _isSearching = true);

    try {
      final results = await ref.read(playersListProvider.notifier).searchUsers(query);
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
    _debounce = Timer(const Duration(milliseconds: 400), () {
      _searchUsers(query);
    });
  }

  void _selectUser(UserSearchResult user) {
    setState(() {
      _selectedUser = user;
      _searchCtrl.clear();
      _searchResults = [];
    });
  }

  void _clearSelectedUser() {
    setState(() {
      _selectedUser = null;
    });
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
                    Expanded(
                      child: Text(
                        'Link ${widget.player.name}',
                        style: Theme.of(context).textTheme.titleLarge?.copyWith(
                              fontWeight: FontWeight.bold,
                            ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
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
                    hintText: 'Find a user account to link...',
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
                  ),
                  onChanged: _onSearchChanged,
                ),
              ),
              // Selected user
              if (_selectedUser != null)
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
                                _selectedUser!.displayName ?? 'No name',
                                style: const TextStyle(fontWeight: FontWeight.w600),
                              ),
                              if (_selectedUser!.email != null)
                                Text(
                                  _selectedUser!.email!,
                                  style: Theme.of(context).textTheme.bodySmall,
                                ),
                            ],
                          ),
                        ),
                        IconButton(
                          icon: const Icon(Icons.close),
                          onPressed: _clearSelectedUser,
                        ),
                      ],
                    ),
                  ),
                ),
              // Search results
              if (_searchResults.isNotEmpty && _selectedUser == null)
                Expanded(
                  child: ListView.builder(
                    controller: scrollController,
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    itemCount: _searchResults.length,
                    itemBuilder: (context, index) {
                      final user = _searchResults[index];
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
                          title: Text(user.displayName ?? 'No name'),
                          subtitle: Text(user.email ?? ''),
                          trailing: const Icon(Icons.link),
                          onTap: () => _selectUser(user),
                        ),
                      );
                    },
                  ),
                )
              else if (_searchResults.isEmpty && _searchCtrl.text.isNotEmpty && !_isSearching && _selectedUser == null)
                Expanded(
                  child: Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.search_off, size: 48, color: Colors.grey.shade400),
                        const SizedBox(height: 8),
                        Text(
                          'No users found',
                          style: TextStyle(color: Colors.grey.shade600),
                        ),
                      ],
                    ),
                  ),
                )
              else if (_selectedUser == null)
                Expanded(
                  child: Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.link, size: 48, color: Colors.grey.shade400),
                        const SizedBox(height: 8),
                        Text(
                          'Search for a user to link',
                          style: TextStyle(color: Colors.grey.shade600),
                        ),
                      ],
                    ),
                  ),
                ),
              // Link button
              if (_selectedUser != null)
                const Spacer(),
              if (_selectedUser != null)
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      onPressed: () => Navigator.pop(context, _selectedUser),
                      icon: const Icon(Icons.link),
                      label: const Text('Link Account'),
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

class ListEmptyState extends StatelessWidget {
  const ListEmptyState({super.key});
  @override
  Widget build(BuildContext context) {
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      children: [
        const SizedBox(height: 80),
        Icon(Icons.people_outline, size: 72, color: Colors.grey.shade400),
        const SizedBox(height: 16),
        Text(
          'Add your poker buddies',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 8),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Text(
            'Search for friends by email to link their accounts. Their stats will sync across all your games together.',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: Colors.grey.shade600,
            ),
          ),
        ),
      ],
    );
  }
}

class _CreatePlayerResult {
  final String name;
  final String? email;
  final String? linkedUserId;
  const _CreatePlayerResult({required this.name, this.email, this.linkedUserId});
}

class _AddPlayerSheet extends ConsumerStatefulWidget {
  const _AddPlayerSheet();
  @override
  ConsumerState<_AddPlayerSheet> createState() => _AddPlayerSheetState();
}

class _AddPlayerSheetState extends ConsumerState<_AddPlayerSheet> {
  final _searchCtrl = TextEditingController();
  final _nameCtrl = TextEditingController();
  Timer? _debounce;
  bool _isSearching = false;
  List<UserSearchResult> _searchResults = [];
  UserSearchResult? _selectedUser;

  @override
  void dispose() {
    _searchCtrl.dispose();
    _nameCtrl.dispose();
    _debounce?.cancel();
    super.dispose();
  }

  Future<void> _searchUsers(String query) async {
    if (query.trim().isEmpty) {
      setState(() {
        _searchResults = [];
        _isSearching = false;
      });
      return;
    }

    setState(() => _isSearching = true);

    try {
      final results = await ref.read(playersListProvider.notifier).searchUsers(query);
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
    _debounce = Timer(const Duration(milliseconds: 400), () {
      _searchUsers(query);
    });
  }

  void _selectUser(UserSearchResult user) {
    setState(() {
      _selectedUser = user;
      _nameCtrl.text = user.displayName ?? user.email ?? 'User';
      _searchCtrl.clear();
      _searchResults = [];
    });
  }

  void _clearSelectedUser() {
    setState(() {
      _selectedUser = null;
      _nameCtrl.clear();
    });
  }

  void _addPlayer() {
    if (_selectedUser == null) return;
    final name = _nameCtrl.text.trim().isEmpty 
        ? (_selectedUser!.displayName ?? _selectedUser!.email ?? 'User')
        : _nameCtrl.text.trim();
    Navigator.pop(
      context,
      _CreatePlayerResult(
        name: name,
        email: _selectedUser!.email,
        linkedUserId: _selectedUser!.id,
      ),
    );
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
                      'Add Player',
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
                    hintText: 'Find a user to add as a player...',
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
                  ),
                  onChanged: _onSearchChanged,
                ),
              ),
              // Selected user
              if (_selectedUser != null) ...[
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
                                _selectedUser!.displayName ?? 'No name',
                                style: const TextStyle(fontWeight: FontWeight.w600),
                              ),
                              if (_selectedUser!.email != null)
                                Text(
                                  _selectedUser!.email!,
                                  style: Theme.of(context).textTheme.bodySmall,
                                ),
                            ],
                          ),
                        ),
                        IconButton(
                          icon: const Icon(Icons.close),
                          onPressed: _clearSelectedUser,
                        ),
                      ],
                    ),
                  ),
                ),
                // Custom name field
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: TextField(
                    controller: _nameCtrl,
                    decoration: InputDecoration(
                      labelText: 'Player name (optional)',
                      hintText: _selectedUser!.displayName ?? 'Custom display name',
                      helperText: 'Leave blank to use their account name',
                    ),
                  ),
                ),
              ],
              // Search results
              if (_searchResults.isNotEmpty && _selectedUser == null)
                Expanded(
                  child: ListView.builder(
                    controller: scrollController,
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    itemCount: _searchResults.length,
                    itemBuilder: (context, index) {
                      final user = _searchResults[index];
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
                          title: Text(user.displayName ?? 'No name'),
                          subtitle: Text(user.email ?? ''),
                          trailing: const Icon(Icons.add_circle_outline),
                          onTap: () => _selectUser(user),
                        ),
                      );
                    },
                  ),
                )
              else if (_searchResults.isEmpty && _searchCtrl.text.isNotEmpty && !_isSearching && _selectedUser == null)
                Expanded(
                  child: Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.search_off, size: 48, color: Colors.grey.shade400),
                        const SizedBox(height: 8),
                        Text(
                          'No users found',
                          style: TextStyle(color: Colors.grey.shade600),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'They need to create an account first',
                          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                color: Colors.grey.shade500,
                              ),
                        ),
                      ],
                    ),
                  ),
                )
              else if (_selectedUser == null)
                Expanded(
                  child: Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.person_search, size: 48, color: Colors.grey.shade400),
                        const SizedBox(height: 8),
                        Text(
                          'Search for a user to add',
                          style: TextStyle(color: Colors.grey.shade600),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'Players must have an account',
                          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                color: Colors.grey.shade500,
                              ),
                        ),
                      ],
                    ),
                  ),
                ),
              // Add button
              if (_selectedUser != null)
                const Spacer(),
              if (_selectedUser != null)
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      onPressed: _addPlayer,
                      icon: const Icon(Icons.person_add),
                      label: const Text('Add Player'),
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
