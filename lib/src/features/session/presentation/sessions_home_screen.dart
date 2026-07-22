import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import '../../../config/backend_contract.dart';
import '../../analytics/data/analytics_providers.dart';
import '../../groups/data/group_providers.dart';
import '../../groups/domain/group_models.dart';

import '../data/sessions_list_providers.dart';
import '../data/session_providers.dart';
import '../data/v2_game_providers.dart';
import '../../../utils/money.dart';
import 'package:poker_ledger/src/features/help/presentation/help_screen.dart';
import 'game_setup_wizard.dart';
import 'session_summary_screen.dart';
import 'v2_game_flow_screen.dart';

enum SessionsStatusFilter { all, inProgress, finalized }

enum SessionsOwnershipFilter { all, hosted, joined }

class SessionsFilter {
  final DateTimeRange? range;
  final SessionsStatusFilter status;
  const SessionsFilter({this.range, this.status = SessionsStatusFilter.all});

  SessionsFilter copyWith({
    DateTimeRange? range,
    SessionsStatusFilter? status,
  }) =>
      SessionsFilter(range: range ?? this.range, status: status ?? this.status);
}

final sessionsFilterProvider = StateProvider<SessionsFilter>(
  (ref) => const SessionsFilter(),
);
final sessionsOwnershipFilterProvider = StateProvider<SessionsOwnershipFilter>(
  (ref) => SessionsOwnershipFilter.all,
);

class SessionsHomeScreen extends ConsumerWidget {
  const SessionsHomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sessionsAsync = ref.watch(sessionsListProvider);
    final filter = ref.watch(sessionsFilterProvider);
    final ownership = ref.watch(sessionsOwnershipFilterProvider);
    String filterSummary(SessionsFilter f) {
      final parts = <String>[];
      if (f.range != null) {
        parts.add(
          '${DateFormat.MMMd().format(f.range!.start)}–${DateFormat.MMMd().format(f.range!.end)}',
        );
      }
      if (f.status != SessionsStatusFilter.all) {
        parts.add(switch (f.status) {
          SessionsStatusFilter.inProgress => 'In progress',
          SessionsStatusFilter.finalized => 'Finalized',
          SessionsStatusFilter.all => 'All',
        });
      }
      return parts.isEmpty ? 'Filter' : parts.join(' • ');
    }

    final hasActiveFilter =
        filter.range != null || filter.status != SessionsStatusFilter.all;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Games'),
        leading: IconButton(
          icon: const Icon(Icons.help_outline),
          onPressed: () => context.showHelp(HelpPage.sessions),
          tooltip: 'Help',
        ),
        actions: [
          IconButton(
            tooltip: 'Enter join code',
            onPressed: () => _enterJoinCode(context, ref),
            icon: const Icon(Icons.password),
          ),
          IconButton(
            tooltip: 'Game invitations',
            onPressed: () => _showPendingInvitations(context, ref),
            icon: const Icon(Icons.notifications_outlined),
          ),
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: TextButton.icon(
              style: TextButton.styleFrom(
                foregroundColor: hasActiveFilter
                    ? Theme.of(context).colorScheme.primary
                    : null,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                minimumSize: const Size(0, 40),
              ),
              icon: Icon(
                hasActiveFilter ? Icons.filter_alt : Icons.filter_list,
              ),
              label: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 120),
                child: Text(
                  filterSummary(filter),
                  overflow: TextOverflow.ellipsis,
                  maxLines: 1,
                ),
              ),
              onPressed: () async {
                await _showFilterSheet(context, ref, filter);
              },
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: SegmentedButton<SessionsOwnershipFilter>(
              segments: const [
                ButtonSegment(
                  value: SessionsOwnershipFilter.all,
                  label: Text('All'),
                ),
                ButtonSegment(
                  value: SessionsOwnershipFilter.hosted,
                  label: Text('Hosted'),
                ),
                ButtonSegment(
                  value: SessionsOwnershipFilter.joined,
                  label: Text('Joined'),
                ),
              ],
              selected: {ownership},
              onSelectionChanged: (selection) =>
                  ref.read(sessionsOwnershipFilterProvider.notifier).state =
                      selection.first,
            ),
          ),
          Expanded(
            child: sessionsAsync.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (error, _) => _GamesLoadError(
                error: error,
                onRetry: () =>
                    ref.read(sessionsListProvider.notifier).refresh(),
              ),
              data: (sessions) {
                // Apply filters locally
                final filtered = sessions.where((sw) {
                  final s = sw.session;
                  final inRange = () {
                    final r = filter.range;
                    if (r == null) return true;
                    return !s.startedAt.isBefore(r.start) &&
                        !s.startedAt.isAfter(r.end);
                  }();
                  final statusOk = switch (filter.status) {
                    SessionsStatusFilter.all => true,
                    SessionsStatusFilter.inProgress => !s.finalized,
                    SessionsStatusFilter.finalized => s.finalized,
                  };
                  final ownershipOk = switch (ownership) {
                    SessionsOwnershipFilter.all => true,
                    SessionsOwnershipFilter.hosted => sw.isOwner,
                    SessionsOwnershipFilter.joined => !sw.isOwner,
                  };
                  return inRange && statusOk && ownershipOk;
                }).toList();

                if (filtered.isEmpty) {
                  return Center(
                    child: Padding(
                      padding: const EdgeInsets.all(32),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            hasActiveFilter
                                ? Icons.filter_alt_off
                                : Icons.casino_outlined,
                            size: 64,
                            color: Colors.grey.shade400,
                          ),
                          const SizedBox(height: 16),
                          Text(
                            hasActiveFilter
                                ? 'No games match your filters'
                                : 'Ready to play?',
                            style: Theme.of(context).textTheme.titleMedium
                                ?.copyWith(fontWeight: FontWeight.bold),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            hasActiveFilter
                                ? 'Try adjusting your date range or status filter'
                                : 'Start a new game to track buy-ins, cash-outs, and who owes who at the end.',
                            textAlign: TextAlign.center,
                            style: Theme.of(context).textTheme.bodyMedium
                                ?.copyWith(color: Colors.grey.shade600),
                          ),
                          if (!hasActiveFilter) ...[
                            const SizedBox(height: 24),
                            FilledButton.icon(
                              onPressed: () => _createNewGame(context, ref),
                              icon: const Icon(Icons.add),
                              label: const Text('Start New Game'),
                            ),
                          ],
                        ],
                      ),
                    ),
                  );
                }
                return RefreshIndicator(
                  onRefresh: () =>
                      ref.read(sessionsListProvider.notifier).refresh(),
                  child: ListView.separated(
                    itemCount: filtered.length,
                    separatorBuilder: (_, __) => const Divider(height: 1),
                    itemBuilder: (_, i) {
                      final sw = filtered[i];
                      final s = sw.session;
                      final started = DateFormat.yMMMd().add_jm().format(
                        s.startedAt,
                      );
                      final status = s.finalized
                          ? 'Finalized'
                          : s.ledgerVersion == 2
                          ? switch (s.phase) {
                              'draft' => 'Lobby',
                              'live' => 'Live',
                              _ => 'In progress',
                            }
                          : 'In progress';
                      final isOwner = sw.isOwner;
                      return ListTile(
                        title: Row(
                          children: [
                            Expanded(
                              child: Text(
                                (s.name == null || s.name!.trim().isEmpty)
                                    ? 'Game #${s.id ?? '-'}'
                                    : s.name!,
                              ),
                            ),
                            if (!isOwner)
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 8,
                                  vertical: 2,
                                ),
                                decoration: BoxDecoration(
                                  color: Colors.grey.shade200,
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                child: Text(
                                  'Joined • ${sw.ownerName}',
                                  style: Theme.of(context).textTheme.labelSmall,
                                ),
                              ),
                          ],
                        ),
                        subtitle: Text('$started • $status'),
                        trailing:
                            isOwner && s.ledgerVersion == 1 && !s.finalized
                            ? IconButton(
                                tooltip: 'Delete game',
                                icon: const Icon(Icons.delete_outline),
                                onPressed: () async {
                                  final ok = await showDialog<bool>(
                                    context: context,
                                    builder: (_) => AlertDialog(
                                      title: const Text('Delete game?'),
                                      content: const Text(
                                        'This action cannot be undone.',
                                      ),
                                      actions: [
                                        TextButton(
                                          onPressed: () =>
                                              Navigator.pop(context, false),
                                          child: const Text('Cancel'),
                                        ),
                                        FilledButton(
                                          onPressed: () =>
                                              Navigator.pop(context, true),
                                          child: const Text('Delete'),
                                        ),
                                      ],
                                    ),
                                  );
                                  if (ok == true) {
                                    if (!context.mounted) return;
                                    if (s.id != null) {
                                      // Optimistically remove the session from the list
                                      ref
                                          .read(sessionsListProvider.notifier)
                                          .removeSessionOptimistically(s.id!);

                                      // Show immediate confirmation
                                      ScaffoldMessenger.of(
                                        context,
                                      ).showSnackBar(
                                        const SnackBar(
                                          content: Text('Game deleted'),
                                        ),
                                      );

                                      // Perform deletion in background
                                      ref
                                          .read(sessionRepositoryProvider)
                                          .deleteSession(s.id!)
                                          .then((_) {
                                            // Refresh data in background
                                            ref
                                                .read(
                                                  analyticsProvider.notifier,
                                                )
                                                .refresh();
                                            ref
                                                .read(
                                                  sessionsListProvider.notifier,
                                                )
                                                .refresh();
                                          })
                                          .catchError((_) {
                                            // Revert on error
                                            ref
                                                .read(
                                                  sessionsListProvider.notifier,
                                                )
                                                .refresh();
                                            if (!context.mounted) return;
                                            ScaffoldMessenger.of(
                                              context,
                                            ).showSnackBar(
                                              const SnackBar(
                                                content: Text(
                                                  'The legacy game could not '
                                                  'be deleted.',
                                                ),
                                              ),
                                            );
                                          });
                                    } else {
                                      ScaffoldMessenger.of(
                                        context,
                                      ).showSnackBar(
                                        const SnackBar(
                                          content: Text(
                                            'Cannot delete game without ID',
                                          ),
                                        ),
                                      );
                                    }
                                  }
                                },
                              )
                            : null,
                        onTap: () => Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) {
                              if (s.ledgerVersion == 2) {
                                return V2GameFlowScreen(sessionId: s.id!);
                              }
                              if (s.finalized || !isOwner) {
                                return SessionSummaryScreen(sessionId: s.id!);
                              }
                              return GameSetupWizard(sessionId: s.id!);
                            },
                          ),
                        ),
                        onLongPress:
                            isOwner && s.ledgerVersion == 1 && !s.finalized
                            ? () async {
                                final controller = TextEditingController(
                                  text: s.name ?? '',
                                );
                                final newName = await showDialog<String?>(
                                  context: context,
                                  builder: (_) => AlertDialog(
                                    title: const Text('Rename game'),
                                    content: TextField(
                                      controller: controller,
                                      decoration: const InputDecoration(
                                        labelText: 'Name (optional)',
                                      ),
                                    ),
                                    actions: [
                                      TextButton(
                                        onPressed: () => Navigator.pop(context),
                                        child: const Text('Cancel'),
                                      ),
                                      FilledButton(
                                        onPressed: () => Navigator.pop(
                                          context,
                                          controller.text.trim(),
                                        ),
                                        child: const Text('Save'),
                                      ),
                                    ],
                                  ),
                                );
                                if (newName != null) {
                                  await ref
                                      .read(sessionRepositoryProvider)
                                      .renameSession(
                                        sessionId: s.id!,
                                        name: newName.isEmpty ? null : newName,
                                      );
                                  await ref
                                      .read(sessionsListProvider.notifier)
                                      .refresh();
                                }
                              }
                            : null,
                      );
                    },
                  ),
                );
              },
            ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        heroTag: 'games-new-game-fab',
        tooltip: 'Start a new poker game',
        onPressed: () => _createNewGame(context, ref),
        icon: const Icon(Icons.add),
        label: const Text('New Game'),
      ),
    );
  }
}

class _GamesLoadError extends StatelessWidget {
  final Object error;
  final VoidCallback onRetry;

  const _GamesLoadError({required this.error, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    final backendUpdateRequired = error is BackendCompatibilityException;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.sync_problem, size: 48),
            const SizedBox(height: 12),
            Text(
              backendUpdateRequired
                  ? 'Poker Ledger is finishing a backend update. Games will '
                        'be available when the update completes.'
                  : 'Games could not be loaded.',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 12),
            FilledButton.tonal(
              onPressed: onRetry,
              child: const Text('Try again'),
            ),
          ],
        ),
      ),
    );
  }
}

Future<void> _createNewGame(BuildContext context, WidgetRef ref) async {
  try {
    final v2Repository = ref.read(v2GameRepositoryProvider);
    final v2Enabled = await v2Repository.isEnabledForCurrentUser();
    if (!context.mounted) return;
    if (!v2Enabled) {
      await showDialog<void>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('New game flow unavailable'),
          content: const Text(
            'New-game creation is temporarily paused or this app version '
            'needs an update. Existing games remain available.',
          ),
          actions: [
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('OK'),
            ),
          ],
        ),
      );
      return;
    }
    final groups = await ref.read(myGroupsProvider.future);
    final manageableGroups = groups
        .where((group) => group.canManageGames && group.archivedAt == null)
        .toList();
    if (!context.mounted) return;
    final draft = await showDialog<_NewGameDraft>(
      context: context,
      builder: (_) => _NewGameDialog(groups: manageableGroups),
    );
    if (draft == null || !context.mounted) return;

    final sessionId = await v2Repository.createGame(
      name: draft.name,
      groupId: draft.groupId,
      defaultBuyInCents: draft.defaultBuyInCents,
      hostParticipates: draft.hostParticipates,
    );
    await ref.read(sessionsListProvider.notifier).refresh();
    if (!context.mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => V2GameFlowScreen(sessionId: sessionId)),
    );
    ref.read(sessionsListProvider.notifier).refresh();
  } catch (_) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('The game could not be created. Please try again.'),
        ),
      );
    }
  }
}

Future<void> _enterJoinCode(BuildContext context, WidgetRef ref) async {
  final controller = TextEditingController();
  final code = await showDialog<String>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('Join a game'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text(
            'Enter the short code the host shared. The host must approve your '
            'request before you join.',
          ),
          const SizedBox(height: 16),
          TextField(
            controller: controller,
            autofocus: true,
            textCapitalization: TextCapitalization.characters,
            decoration: const InputDecoration(
              labelText: 'Join code',
              hintText: 'A1B2C3D4E5F6',
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () {
            final code = controller.text.trim();
            if (code.isNotEmpty) Navigator.pop(dialogContext, code);
          },
          child: const Text('Request to join'),
        ),
      ],
    ),
  );
  controller.dispose();
  if (code == null) return;
  try {
    final result = await ref.read(v2GameRepositoryProvider).requestJoin(code);
    if (!context.mounted) return;
    final status = result['status'] as String?;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          status == 'participating' || status == 'accepted'
              ? 'You are already in this game.'
              : status == 'pending_invitee'
              ? 'You already have an invitation to this game.'
              : 'Request sent. The host will approve or decline it.',
        ),
      ),
    );
    if (status == 'participating' || status == 'accepted') {
      final sessionId = result['session_id'] as int;
      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => V2GameFlowScreen(sessionId: sessionId),
        ),
      );
    }
  } catch (_) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('That code is invalid, expired, or unavailable.'),
        ),
      );
    }
  }
}

Future<void> _showPendingInvitations(
  BuildContext context,
  WidgetRef ref,
) async {
  ref.invalidate(pendingGameInvitationsProvider);
  await showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (sheetContext) => Consumer(
      builder: (modalContext, ref, _) {
        final invitations = ref.watch(pendingGameInvitationsProvider);
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: invitations.when(
              loading: () => const SizedBox(
                height: 240,
                child: Center(child: CircularProgressIndicator()),
              ),
              error: (_, __) => const SizedBox(
                height: 240,
                child: Center(child: Text('Invitations could not be loaded.')),
              ),
              data: (items) => SizedBox(
                height: 320,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      'Game invitations',
                      style: Theme.of(modalContext).textTheme.headlineSmall,
                    ),
                    const SizedBox(height: 12),
                    if (items.isEmpty)
                      const Expanded(
                        child: Center(
                          child: Text('You have no pending invitations.'),
                        ),
                      )
                    else
                      Expanded(
                        child: ListView.builder(
                          itemCount: items.length,
                          itemBuilder: (itemContext, index) {
                            final invitation = items[index];
                            return Card(
                              child: ListTile(
                                leading: const CircleAvatar(
                                  child: Icon(Icons.casino),
                                ),
                                title: const Text('Poker game invitation'),
                                subtitle: Text(
                                  invitation.handle == null
                                      ? 'Open the invitation to respond.'
                                      : 'Invited as @${invitation.handle}',
                                ),
                                trailing: Wrap(
                                  children: [
                                    IconButton(
                                      tooltip: 'Decline',
                                      onPressed: () async {
                                        await ref
                                            .read(v2GameRepositoryProvider)
                                            .respondToInvitation(
                                              invitation.id,
                                              false,
                                            );
                                        ref.invalidate(
                                          pendingGameInvitationsProvider,
                                        );
                                      },
                                      icon: const Icon(Icons.close),
                                    ),
                                    IconButton(
                                      tooltip: 'Accept',
                                      onPressed: () async {
                                        await ref
                                            .read(v2GameRepositoryProvider)
                                            .respondToInvitation(
                                              invitation.id,
                                              true,
                                            );
                                        ref.invalidate(
                                          pendingGameInvitationsProvider,
                                        );
                                        ref
                                            .read(sessionsListProvider.notifier)
                                            .refresh();
                                        if (sheetContext.mounted) {
                                          Navigator.pop(sheetContext);
                                        }
                                        if (context.mounted) {
                                          await Navigator.of(context).push(
                                            MaterialPageRoute(
                                              builder: (_) => V2GameFlowScreen(
                                                sessionId: invitation.sessionId,
                                              ),
                                            ),
                                          );
                                        }
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

class _NewGameDraft {
  final String? name;
  final int? groupId;
  final int defaultBuyInCents;
  final bool hostParticipates;

  const _NewGameDraft({
    required this.name,
    required this.groupId,
    required this.defaultBuyInCents,
    required this.hostParticipates,
  });
}

class _NewGameDialog extends StatefulWidget {
  final List<Group> groups;

  const _NewGameDialog({required this.groups});

  @override
  State<_NewGameDialog> createState() => _NewGameDialogState();
}

class _NewGameDialogState extends State<_NewGameDialog> {
  final _nameController = TextEditingController();
  final _buyInController = TextEditingController(text: '20.00');
  int? _groupId;
  bool _hostParticipates = true;
  String? _buyInError;

  @override
  void dispose() {
    _nameController.dispose();
    _buyInController.dispose();
    super.dispose();
  }

  void _submit() {
    final cents = Money.tryParseCents(_buyInController.text);
    if (cents == null || cents <= 0) {
      setState(() => _buyInError = 'Enter a buy-in greater than zero.');
      return;
    }
    Navigator.pop(
      context,
      _NewGameDraft(
        name: _nameController.text.trim().isEmpty
            ? null
            : _nameController.text.trim(),
        groupId: _groupId,
        defaultBuyInCents: cents,
        hostParticipates: _hostParticipates,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('New poker game'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _nameController,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(
                labelText: 'Game name (optional)',
                hintText: 'Friday night poker',
              ),
            ),
            const SizedBox(height: 16),
            DropdownButtonFormField<int?>(
              initialValue: _groupId,
              decoration: const InputDecoration(
                labelText: 'Visibility',
                helperText:
                    'A group game is visible in full to every current member.',
              ),
              items: [
                const DropdownMenuItem<int?>(
                  value: null,
                  child: Text('Private game'),
                ),
                ...widget.groups
                    .where((group) => group.archivedAt == null)
                    .map(
                      (group) => DropdownMenuItem<int?>(
                        value: group.id,
                        child: Text(group.name),
                      ),
                    ),
              ],
              onChanged: (value) => setState(() => _groupId = value),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _buyInController,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              decoration: InputDecoration(
                labelText: 'Default buy-in',
                prefixText: '\$',
                errorText: _buyInError,
              ),
            ),
            const SizedBox(height: 8),
            SwitchListTile(
              value: _hostParticipates,
              onChanged: (value) => setState(() => _hostParticipates = value),
              contentPadding: EdgeInsets.zero,
              title: const Text('I am playing'),
              subtitle: const Text(
                'Turn this off if you are only hosting or keeping the ledger.',
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(onPressed: _submit, child: const Text('Create lobby')),
      ],
    );
  }
}

Future<void> _showFilterSheet(
  BuildContext context,
  WidgetRef ref,
  SessionsFilter filter,
) async {
  final theme = Theme.of(context);
  var localRange = filter.range;
  var localStatus = filter.status;
  await showModalBottomSheet(
    context: context,
    showDragHandle: true,
    builder: (_) {
      return StatefulBuilder(
        builder: (context, setState) {
          return Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Filters', style: theme.textTheme.titleMedium),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        icon: const Icon(Icons.date_range),
                        label: Text(
                          localRange == null
                              ? 'Date range'
                              : '${DateFormat.yMMMd().format(localRange!.start)} – ${DateFormat.yMMMd().format(localRange!.end)}',
                          overflow: TextOverflow.ellipsis,
                          maxLines: 1,
                          softWrap: false,
                        ),
                        onPressed: () async {
                          final picked = await showDateRangePicker(
                            context: context,
                            firstDate: DateTime(2000),
                            lastDate: DateTime.now().add(
                              const Duration(days: 365 * 5),
                            ),
                            initialDateRange: localRange,
                          );
                          if (picked != null) {
                            setState(() => localRange = picked);
                          }
                        },
                      ),
                    ),
                    const SizedBox(width: 12),
                  ],
                ),
                const SizedBox(height: 12),
                SegmentedButton<SessionsStatusFilter>(
                  segments: const [
                    ButtonSegment(
                      value: SessionsStatusFilter.all,
                      label: Text(
                        'All',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        softWrap: false,
                      ),
                      icon: Icon(Icons.all_inclusive),
                    ),
                    ButtonSegment(
                      value: SessionsStatusFilter.inProgress,
                      label: Text(
                        'In progress',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        softWrap: false,
                      ),
                      icon: Icon(Icons.play_arrow),
                    ),
                    ButtonSegment(
                      value: SessionsStatusFilter.finalized,
                      label: Text(
                        'Finalized',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        softWrap: false,
                      ),
                      icon: Icon(Icons.flag),
                    ),
                  ],
                  selected: {localStatus},
                  onSelectionChanged: (s) =>
                      setState(() => localStatus = s.first),
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    TextButton(
                      onPressed: () {
                        ref.read(sessionsFilterProvider.notifier).state =
                            const SessionsFilter();
                        Navigator.pop(context);
                      },
                      child: const Text('Clear'),
                    ),
                    const Spacer(),
                    FilledButton(
                      onPressed: () {
                        ref.read(sessionsFilterProvider.notifier).state = filter
                            .copyWith(range: localRange, status: localStatus);
                        Navigator.pop(context);
                      },
                      child: const Text('Apply'),
                    ),
                  ],
                ),
              ],
            ),
          );
        },
      );
    },
  );
}
