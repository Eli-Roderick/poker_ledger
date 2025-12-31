import 'package:flutter/material.dart';
import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../analytics/data/analytics_providers.dart';

import '../../players/data/players_providers.dart';
import '../../players/domain/player.dart';

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
        onPressed: () async {
          final created = await showDialog<_CreatePlayerResult?>(
            context: context,
            builder: (context) => const _CreatePlayerDialog(),
          );
          if (created != null && created.name.trim().isNotEmpty) {
            await ref.read(playersListProvider.notifier).addPlayer(
                  name: created.name.trim(),
                  email: created.email?.trim(),
                  phone: created.phone?.trim(),
                  linkedUserId: created.linkedUserId,
                );
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
        title: Row(
          children: [
            Expanded(child: Text(player.name)),
            if (player.isLinked)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: Colors.green.shade50,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.green.shade200),
                ),
                child: Text(
                  'Linked',
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(color: Colors.green),
                ),
              )
            else
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: Colors.grey.shade100,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  'Guest',
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(color: Colors.grey),
                ),
              ),
          ],
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (player.linkedUserDisplayName != null)
              Text('→ ${player.linkedUserDisplayName}', style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Colors.green)),
            if (player.email != null && player.email!.isNotEmpty)
              Text(player.email!, style: Theme.of(context).textTheme.bodySmall),
            if (player.phone != null && player.phone!.isNotEmpty)
              Text(player.phone!, style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Theme.of(context).colorScheme.outline)),
          ],
        ),
        onTap: () async {
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
        },
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
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
                    // Refresh analytics so deactivated player's nets disappear immediately
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
                  // Refresh analytics so reactivated player's nets reappear if present
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

class ListEmptyState extends StatelessWidget {
  const ListEmptyState({super.key});
  @override
  Widget build(BuildContext context) {
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      children: const [
        SizedBox(height: 120),
        Icon(Icons.people_outline, size: 72, color: Colors.white70),
        SizedBox(height: 12),
        Center(child: Text('No players yet. Tap "+ Add Player" to create one.')),
      ],
    );
  }
}

class _CreatePlayerResult {
  final String name;
  final String? email;
  final String? phone;
  final String? linkedUserId;
  const _CreatePlayerResult({required this.name, this.email, this.phone, this.linkedUserId});
}

class _CreatePlayerDialog extends ConsumerStatefulWidget {
  const _CreatePlayerDialog();
  @override
  ConsumerState<_CreatePlayerDialog> createState() => _CreatePlayerDialogState();
}

class _CreatePlayerDialogState extends ConsumerState<_CreatePlayerDialog> {
  final _formKey = GlobalKey<FormState>();
  final _nameCtrl = TextEditingController();
  final _emailCtrl = TextEditingController();
  final _phoneCtrl = TextEditingController();
  final _searchCtrl = TextEditingController();
  
  bool _isSearchingUsers = false;
  List<UserSearchResult> _searchResults = [];
  UserSearchResult? _selectedUser;
  Timer? _debounce;

  @override
  void dispose() {
    _nameCtrl.dispose();
    _emailCtrl.dispose();
    _phoneCtrl.dispose();
    _searchCtrl.dispose();
    _debounce?.cancel();
    super.dispose();
  }

  Future<void> _searchUsers(String query) async {
    if (query.trim().isEmpty) {
      setState(() {
        _searchResults = [];
        _isSearchingUsers = false;
      });
      return;
    }
    
    setState(() => _isSearchingUsers = true);
    
    try {
      final results = await ref.read(playersListProvider.notifier).searchUsers(query);
      if (mounted) {
        setState(() {
          _searchResults = results;
          _isSearchingUsers = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isSearchingUsers = false);
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
      _emailCtrl.text = user.email ?? '';
      _searchCtrl.clear();
      _searchResults = [];
    });
  }

  void _clearSelectedUser() {
    setState(() {
      _selectedUser = null;
      _nameCtrl.clear();
      _emailCtrl.clear();
    });
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Add Player'),
      content: Form(
        key: _formKey,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Search for an existing user or create a guest:',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Colors.grey),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _searchCtrl,
                decoration: InputDecoration(
                  labelText: 'Search users by email/name',
                  prefixIcon: const Icon(Icons.search),
                  suffixIcon: _isSearchingUsers 
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: Padding(
                            padding: EdgeInsets.all(12),
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                        )
                      : null,
                ),
                onChanged: _onSearchChanged,
              ),
              if (_searchResults.isNotEmpty) ...[
                const SizedBox(height: 8),
                Container(
                  constraints: const BoxConstraints(maxHeight: 150),
                  decoration: BoxDecoration(
                    border: Border.all(color: Colors.grey.shade300),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: ListView.builder(
                    shrinkWrap: true,
                    itemCount: _searchResults.length,
                    itemBuilder: (context, index) {
                      final user = _searchResults[index];
                      return ListTile(
                        dense: true,
                        leading: const Icon(Icons.person),
                        title: Text(user.displayName ?? 'No name'),
                        subtitle: Text(user.email ?? ''),
                        onTap: () => _selectUser(user),
                      );
                    },
                  ),
                ),
              ],
              if (_selectedUser != null) ...[
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.green.shade50,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Colors.green.shade200),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.link, color: Colors.green),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Linked to user',
                              style: Theme.of(context).textTheme.labelSmall?.copyWith(color: Colors.green),
                            ),
                            Text(_selectedUser!.displayName ?? _selectedUser!.email ?? 'User'),
                          ],
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.close, size: 18),
                        onPressed: _clearSelectedUser,
                      ),
                    ],
                  ),
                ),
              ],
              const SizedBox(height: 16),
              const Divider(),
              const SizedBox(height: 8),
              Text(
                _selectedUser != null ? 'Player details (from linked user):' : 'Guest player details:',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Colors.grey),
              ),
              const SizedBox(height: 8),
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
                _CreatePlayerResult(
                  name: _nameCtrl.text,
                  email: _emailCtrl.text.isEmpty ? null : _emailCtrl.text,
                  phone: _phoneCtrl.text.isEmpty ? null : _phoneCtrl.text,
                  linkedUserId: _selectedUser?.id,
                ),
              );
            }
          },
          child: Text(_selectedUser != null ? 'Add Linked Player' : 'Add Guest'),
        ),
      ],
    );
  }
}
