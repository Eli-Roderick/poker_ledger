import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import '../../analytics/data/analytics_providers.dart';

import '../data/sessions_list_providers.dart';
import '../data/session_providers.dart';
import 'package:poker_ledger/src/features/help/presentation/help_screen.dart';
import 'session_detail_screen.dart';

enum SessionsStatusFilter { all, inProgress, finalized }

class SessionsFilter {
  final DateTimeRange? range;
  final SessionsStatusFilter status;
  const SessionsFilter({this.range, this.status = SessionsStatusFilter.all});

  SessionsFilter copyWith({DateTimeRange? range, SessionsStatusFilter? status}) =>
      SessionsFilter(range: range ?? this.range, status: status ?? this.status);
}

final sessionsFilterProvider = StateProvider<SessionsFilter>((ref) => const SessionsFilter());

class SessionsHomeScreen extends ConsumerWidget {
  const SessionsHomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sessionsAsync = ref.watch(sessionsListProvider);
    final filter = ref.watch(sessionsFilterProvider);
    String _filterSummary(SessionsFilter f) {
      final parts = <String>[];
      if (f.range != null) {
        parts.add('${DateFormat.MMMd().format(f.range!.start)}–${DateFormat.MMMd().format(f.range!.end)}');
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

    final hasActiveFilter = filter.range != null || filter.status != SessionsStatusFilter.all;
    
    // Sessions list only shows user's own sessions
    // Shared sessions only appear in Analytics when filtering by group
    
    return Scaffold(
      appBar: AppBar(
        title: const Text('My Sessions'),
        leading: IconButton(
          icon: const Icon(Icons.help_outline),
          onPressed: () => context.showHelp(HelpPage.sessions),
          tooltip: 'Help',
        ),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: TextButton.icon(
              style: TextButton.styleFrom(
                foregroundColor: hasActiveFilter ? Theme.of(context).colorScheme.primary : null,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                minimumSize: const Size(0, 40),
              ),
              icon: Icon(hasActiveFilter ? Icons.filter_alt : Icons.filter_list),
              label: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 120),
                child: Text(
                  _filterSummary(filter),
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
      body: sessionsAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, st) => Center(child: Text('Error: $e')),
        data: (sessions) {
          // Apply filters locally
          final filtered = sessions.where((sw) {
            final s = sw.session;
            final inRange = () {
              final r = filter.range;
              if (r == null) return true;
              return !s.startedAt.isBefore(r.start) && !s.startedAt.isAfter(r.end);
            }();
            final statusOk = switch (filter.status) {
              SessionsStatusFilter.all => true,
              SessionsStatusFilter.inProgress => !s.finalized,
              SessionsStatusFilter.finalized => s.finalized,
            };
            return inRange && statusOk;
          }).toList();

          if (filtered.isEmpty) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      hasActiveFilter ? Icons.filter_alt_off : Icons.casino_outlined,
                      size: 64,
                      color: Colors.grey.shade400,
                    ),
                    const SizedBox(height: 16),
                    Text(
                      hasActiveFilter
                          ? 'No sessions match your filters'
                          : 'No sessions yet',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      hasActiveFilter
                          ? 'Try adjusting your date range or status filter'
                          : 'Tap "New Session" to start tracking a poker game. Add players, record buy-ins and cash-outs, then settle up at the end.',
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: Colors.grey.shade600,
                      ),
                    ),
                  ],
                ),
              ),
            );
          }
          return RefreshIndicator(
            onRefresh: () => ref.read(sessionsListProvider.notifier).refresh(),
            child: ListView.separated(
              itemCount: filtered.length,
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (_, i) {
                final sw = filtered[i];
                final s = sw.session;
                final started = DateFormat.yMMMd().add_jm().format(s.startedAt);
                final status = s.finalized ? 'Finalized' : 'In progress';
                final isOwner = sw.isOwner;
                return ListTile(
                  title: Row(
                    children: [
                      Expanded(
                        child: Text((s.name == null || s.name!.trim().isEmpty) ? 'Session #${s.id ?? '-'}' : s.name!),
                      ),
                      if (!isOwner)
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                          decoration: BoxDecoration(
                            color: Colors.grey.shade200,
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Text(
                            'From ${sw.ownerName}',
                            style: Theme.of(context).textTheme.labelSmall,
                          ),
                        ),
                    ],
                  ),
                  subtitle: Text('$started • $status'),
                  trailing: isOwner
                      ? IconButton(
                          tooltip: 'Delete session',
                          icon: const Icon(Icons.delete_outline),
                          onPressed: () async {
                            final ok = await showDialog<bool>(
                              context: context,
                              builder: (_) => AlertDialog(
                                title: const Text('Delete session?'),
                                content: const Text('This action cannot be undone.'),
                                actions: [
                                  TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
                                  FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Delete')),
                                ],
                              ),
                            );
                            if (ok == true) {
                              await ref.read(sessionRepositoryProvider).deleteSession(s.id!);
                              await ref.read(analyticsProvider.notifier).refresh();
                              await ref.read(sessionsListProvider.notifier).refresh();
                              if (context.mounted) {
                                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Session deleted')));
                              }
                            }
                          },
                        )
                      : null,
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => SessionDetailScreen(sessionId: s.id!)),
                  ),
                  onLongPress: isOwner
                      ? () async {
                          final controller = TextEditingController(text: s.name ?? '');
                          final newName = await showDialog<String?>(
                            context: context,
                            builder: (_) => AlertDialog(
                              title: const Text('Rename session'),
                              content: TextField(
                                controller: controller,
                                decoration: const InputDecoration(labelText: 'Name (optional)'),
                              ),
                              actions: [
                                TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
                                FilledButton(onPressed: () => Navigator.pop(context, controller.text.trim()), child: const Text('Save')),
                              ],
                            ),
                          );
                          if (newName != null) {
                            await ref.read(sessionRepositoryProvider).renameSession(sessionId: s.id!, name: newName.isEmpty ? null : newName);
                            await ref.read(sessionsListProvider.notifier).refresh();
                          }
                        }
                      : null,
                );
              },
            ),
          );
        },
      ),
      floatingActionButton: FloatingActionButton.extended(
        tooltip: 'Start a new poker session',
        onPressed: () async {
          // Prompt for an optional name
          final controller = TextEditingController();
          final name = await showDialog<String?>(
            context: context,
            builder: (_) => AlertDialog(
              title: const Text('New session'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  TextField(
                    controller: controller,
                    decoration: const InputDecoration(
                      labelText: 'Name (optional)',
                      hintText: 'e.g., Friday Night Game',
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    'You can add players and set buy-ins after creating the session.',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Colors.grey),
                  ),
                ],
              ),
              actions: [
                TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
                FilledButton(onPressed: () => Navigator.pop(context, controller.text.trim()), child: const Text('Create')),
              ],
            ),
          );
          if (name == null) return; // user cancelled; do not create a session
          if (!context.mounted) return;
          // Create a new session and open its details
          final newSession = await ref.read(sessionRepositoryProvider).createSession(name: name.isEmpty ? null : name);
          if (context.mounted) {
            // refresh list
            ref.read(sessionsListProvider.notifier).refresh();
            Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => SessionDetailScreen(sessionId: newSession.id!)),
            );
          }
        },
        icon: const Icon(Icons.add),
        label: const Text('New Session'),
      ),
    );
  }
}

Future<void> _showFilterSheet(BuildContext context, WidgetRef ref, SessionsFilter filter) async {
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
                            lastDate: DateTime.now().add(const Duration(days: 365 * 5)),
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
                      label: Text('All', maxLines: 1, overflow: TextOverflow.ellipsis, softWrap: false),
                      icon: Icon(Icons.all_inclusive),
                    ),
                    ButtonSegment(
                      value: SessionsStatusFilter.inProgress,
                      label: Text('In progress', maxLines: 1, overflow: TextOverflow.ellipsis, softWrap: false),
                      icon: Icon(Icons.play_arrow),
                    ),
                    ButtonSegment(
                      value: SessionsStatusFilter.finalized,
                      label: Text('Finalized', maxLines: 1, overflow: TextOverflow.ellipsis, softWrap: false),
                      icon: Icon(Icons.flag),
                    ),
                  ],
                  selected: {localStatus},
                  onSelectionChanged: (s) => setState(() => localStatus = s.first),
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    TextButton(
                      onPressed: () {
                        ref.read(sessionsFilterProvider.notifier).state = const SessionsFilter();
                        Navigator.pop(context);
                      },
                      child: const Text('Clear'),
                    ),
                    const Spacer(),
                    FilledButton(
                      onPressed: () {
                        ref.read(sessionsFilterProvider.notifier).state = filter.copyWith(range: localRange, status: localStatus);
                        Navigator.pop(context);
                      },
                      child: const Text('Apply'),
                    )
                  ],
                )
              ],
            ),
          );
        },
      );
    },
  );
}
