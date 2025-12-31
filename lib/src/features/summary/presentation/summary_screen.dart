import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:path_provider/path_provider.dart';
import 'package:csv/csv.dart';
import 'package:share_plus/share_plus.dart';

import '../data/summary_providers.dart' as sp;
import '../../session/domain/session_models.dart';

class SummaryScreen extends ConsumerWidget {
  static const routeName = '/summary';
  const SummaryScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final summaryAsync = ref.watch(sp.summaryProvider);
    final currency = NumberFormat.simpleCurrency();

    return Scaffold(
      appBar: AppBar(
        title: const Text('Summary'),
        actions: [
          PopupMenuButton<String>(
            onSelected: (v) async {
              final s = summaryAsync.value;
              if (s == null) return;
              if (v == 'share') {
                final text = _buildShareText(s, currency);
                await SharePlus.instance.share(ShareParams(text: text, subject: 'Poker Ledger Summary'));
              } else if (v == 'export_csv') {
                await _exportCsv(s, currency, context);
              }
            },
            itemBuilder: (context) => const [
              PopupMenuItem(value: 'share', child: Text('Share summary')),
              PopupMenuItem(value: 'export_csv', child: Text('Export CSV')),
            ],
          ),
        ],
      ),
      body: summaryAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, st) => Center(child: Text('Error: $e')),
        data: (state) {
          return Column(
            children: [
              _FiltersBar(
                filters: state.filters,
                onChanged: (f) => ref.read(sp.summaryProvider.notifier).setFilters(f),
              ),
              const Divider(height: 1),
              _TotalsBar(
                buyIns: state.globalBuyInsCents,
                cashOuts: state.globalCashOutsCents,
                diff: state.globalDiffCents,
                currency: currency,
              ),
              const Divider(height: 1),
              Expanded(
                child: ListView.separated(
                  itemCount: state.entries.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (_, i) {
                    final e = state.entries[i];
                    final title = 'Session #${e.session.id ?? '-'}';
                    final subtitle = _formatSessionSubtitle(e.session);
                    return ListTile(
                      title: Text(title),
                      subtitle: Text(subtitle),
                      trailing: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          Text('Buy-ins: ${currency.format(e.buyInsTotalCents / 100)}'),
                          Text('Cash-outs: ${currency.format(e.cashOutsTotalCents / 100)}'),
                          Text(
                            'Diff: ${currency.format(e.diffCents / 100)}',
                            style: TextStyle(
                              color: e.diffCents == 0
                                  ? Theme.of(context).colorScheme.outline
                                  : (e.diffCents > 0
                                      ? Colors.green
                                      : Colors.red),
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  String _formatSessionSubtitle(Session s) {
    final start = DateFormat.yMMMd().add_jm().format(s.startedAt);
    final status = s.finalized ? 'Finalized' : 'In progress';
    return '$start • $status';
  }

  String _buildShareText(sp.SummaryState s, NumberFormat currency) {
    final b = StringBuffer();
    b.writeln('Summary');
    for (final e in s.entries) {
      b.writeln(
          'Session #${e.session.id ?? '-'} — Buy-ins: ${currency.format(e.buyInsTotalCents / 100)}, Cash-outs: ${currency.format(e.cashOutsTotalCents / 100)}, Diff: ${currency.format(e.diffCents / 100)}');
    }
    b.writeln('---');
    b.writeln('Totals:');
    b.writeln('Buy-ins: ${currency.format(s.globalBuyInsCents / 100)}');
    b.writeln('Cash-outs: ${currency.format(s.globalCashOutsCents / 100)}');
    b.writeln('Diff: ${currency.format(s.globalDiffCents / 100)}');
    return b.toString();
  }

  Future<void> _exportCsv(sp.SummaryState s, NumberFormat currency, BuildContext context) async {
    final rows = <List<dynamic>>[];
    rows.add(['Session ID', 'Started At', 'Finalized', 'Buy-ins', 'Cash-outs', 'Diff']);
    for (final e in s.entries) {
      rows.add([
        e.session.id,
        e.session.startedAt.toIso8601String(),
        e.session.finalized ? 'Yes' : 'No',
        (e.buyInsTotalCents / 100).toStringAsFixed(2),
        (e.cashOutsTotalCents / 100).toStringAsFixed(2),
        (e.diffCents / 100).toStringAsFixed(2),
      ]);
    }
    rows.add(['TOTALS', '', '', (s.globalBuyInsCents / 100).toStringAsFixed(2), (s.globalCashOutsCents / 100).toStringAsFixed(2), (s.globalDiffCents / 100).toStringAsFixed(2)]);

    final csv = const ListToCsvConverter().convert(rows);
    final dir = await getTemporaryDirectory();
    final file = await File('${dir.path}/summary_${DateTime.now().millisecondsSinceEpoch}.csv').create();
    await file.writeAsString(csv);
    await SharePlus.instance.share(ShareParams(files: [XFile(file.path)], text: 'Poker Ledger Summary'));
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('CSV exported')));
    }
  }
}

class _FiltersBar extends StatelessWidget {
  final sp.SummaryFilters filters;
  final ValueChanged<sp.SummaryFilters> onChanged;
  const _FiltersBar({required this.filters, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(12.0),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Date range', style: Theme.of(context).textTheme.labelLarge),
                const SizedBox(height: 4),
                Row(
                  children: [
                    _DateChip(
                      label: 'Start',
                      date: filters.range?.start,
                      onTap: () async {
                        final picked = await _pickDate(context, filters.range?.start ?? DateTime.now());
                        if (picked != null) {
                          onChanged(
                            filters.copyWith(
                              range: sp.DateTimeRange(
                                start: picked,
                                end: filters.range?.end ?? picked,
                              ),
                            ),
                          );
                        }
                      },
                    ),
                    const SizedBox(width: 8),
                    _DateChip(
                      label: 'End',
                      date: filters.range?.end,
                      onTap: () async {
                        final picked = await _pickDate(context, filters.range?.end ?? DateTime.now());
                        if (picked != null) {
                          onChanged(
                            filters.copyWith(
                              range: sp.DateTimeRange(
                                start: filters.range?.start ?? picked,
                                end: picked,
                              ),
                            ),
                          );
                        }
                      },
                    ),
                  ],
                ),
              ],
            ),
          ),
          Row(
            children: [
              const Text('Include in-progress'),
              Switch(
                value: filters.includeInProgress,
                onChanged: (v) => onChanged(filters.copyWith(includeInProgress: v)),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Future<DateTime?> _pickDate(BuildContext context, DateTime initial) async {
    final now = DateTime.now();
    final first = DateTime(now.year - 5);
    final last = DateTime(now.year + 5);
    final res = await showDatePicker(context: context, initialDate: initial, firstDate: first, lastDate: last);
    return res;
  }
}

class _DateChip extends StatelessWidget {
  final String label;
  final DateTime? date;
  final VoidCallback onTap;
  const _DateChip({required this.label, required this.date, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final text = date == null ? 'Any' : DateFormat.yMMMd().format(date!);
    return ActionChip(label: Text('$label: $text'), onPressed: onTap);
  }
}

class _TotalsBar extends StatelessWidget {
  final int buyIns;
  final int cashOuts;
  final int diff;
  final NumberFormat currency;
  const _TotalsBar({required this.buyIns, required this.cashOuts, required this.diff, required this.currency});

  @override
  Widget build(BuildContext context) {
    final diffColor = diff == 0
        ? Theme.of(context).colorScheme.outline
        : (diff > 0 ? Colors.green : Colors.red);
    return Padding(
      padding: const EdgeInsets.all(12.0),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text('Buy-ins: ${currency.format(buyIns / 100)}'),
          Text('Cash-outs: ${currency.format(cashOuts / 100)}'),
          Text('Diff: ${currency.format(diff / 100)}', style: TextStyle(color: diffColor)),
        ],
      ),
    );
  }
}
