import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'dart:async';
import 'package:share_plus/share_plus.dart';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'package:csv/csv.dart';

import '../data/session_detail_providers.dart';
import '../data/session_providers.dart';
import '../../groups/data/group_providers.dart';

class SessionSummaryScreen extends ConsumerStatefulWidget {
  final int sessionId;
  final bool showAppBar;
  const SessionSummaryScreen({super.key, required this.sessionId, this.showAppBar = true});

  @override
  ConsumerState<SessionSummaryScreen> createState() => _SessionSummaryScreenState();
}

class _SessionSummaryScreenState extends ConsumerState<SessionSummaryScreen> {
  final _controllers = <int, TextEditingController>{};
  // Live settlement computation based on current text fields
  final ValueNotifier<List<_Transfer>> _transfersNotifier = ValueNotifier<List<_Transfer>>(<_Transfer>[]);
  final ValueNotifier<List<_BankerLine>> _bankerLinesNotifier = ValueNotifier<List<_BankerLine>>(<_BankerLine>[]);
  final Map<int, Timer> _saveDebouncers = <int, Timer>{};

  @override
  void dispose() {
    for (final c in _controllers.values) {
      c.dispose();
    }
    for (final t in _saveDebouncers.values) {
      t.cancel();
    }
    _transfersNotifier.dispose();
    _bankerLinesNotifier.dispose();
    super.dispose();
  }

  String _fmtCents(int cents) => NumberFormat.simpleCurrency().format(cents / 100);

  @override
  Widget build(BuildContext context) {
    final asyncState = ref.watch(sessionDetailProvider(widget.sessionId));
    return Scaffold(
      appBar: widget.showAppBar ? AppBar(
        title: const Text('Summary'),
        actions: [
          IconButton(
            tooltip: 'Share summary',
            icon: const Icon(Icons.share_outlined),
            onPressed: () async {
              final detail = await ref.read(sessionDetailProvider(widget.sessionId).future);
              final summary = _buildShareText(detail);
              await SharePlus.instance.share(ShareParams(text: summary, subject: 'Poker Game Summary'));
            },
          ),
          IconButton(
            tooltip: 'Export CSV',
            icon: const Icon(Icons.download_outlined),
            onPressed: () async {
              await _exportCsv();
            },
          ),
        ],
      ) : null,
      body: asyncState.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, st) => Center(child: Text('Error: $e')),
        data: (data) {
          final participants = data.participants;
          // Prepare controllers
          for (final p in participants) {
            _controllers.putIfAbsent(
              p.id!,
              () => TextEditingController(
                text: p.cashOutCents == null ? '' : (p.cashOutCents! / 100).toStringAsFixed(2),
              ),
            );
          }

          // Helper to compute balances from current text fields (live)
          List<_Balance> _computeBalances() {
            return participants.map((p) {
              final raw = _controllers[p.id]!.text.trim();
              final entered = raw.isEmpty ? (p.cashOutCents ?? 0) : _parseMoneyToCents(raw);
              final net = entered - p.buyInCentsTotal; // positive = won, negative = lost
              return _Balance(playerId: p.playerId, sessionPlayerId: p.id!, netCents: net);
            }).toList();
          }

          final isBanker = data.session.settlementMode == 'banker' && data.session.bankerSessionPlayerId != null;
          final bankerSpId = data.session.bankerSessionPlayerId;

          void _recomputeSettlement() {
            if (isBanker && bankerSpId != null) {
              _bankerLinesNotifier.value = _computeBankerSettlementFromParticipants(
                // synthesize participants with live cash-out values for accurate preview
                participants.map((p) {
                  final raw = _controllers[p.id]!.text.trim();
                  final entered = raw.isEmpty ? p.cashOutCents : _parseMoneyToCents(raw);
                  return _ParticipantProxy(
                    id: p.id!,
                    playerId: p.playerId,
                    buyInCentsTotal: p.buyInCentsTotal,
                    cashOutCents: entered,
                    paidUpfront: p.paidUpfront,
                  );
                }).toList(),
                bankerSpId,
              );
            } else {
              _transfersNotifier.value = _computeSettlement(_computeBalances());
            }
          }

          // Attach listeners once per controller to update settlement preview
          for (final p in participants) {
            final c = _controllers[p.id]!;
            c.removeListener(_recomputeSettlement);
            c.addListener(_recomputeSettlement);
          }

          // Initial compute
          _recomputeSettlement();

          // Totals for zero-sum check
          final totalBuyIns = participants.fold<int>(0, (sum, p) => sum + p.buyInCentsTotal);
          final totalCashOuts = participants.fold<int>(0, (sum, p) => sum + (p.cashOutCents ?? 0));
          final delta = totalCashOuts - totalBuyIns; // should be 0 normally (ignoring rake)

          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              // Player rows with cash out fields
              ...participants.map((p) {
                final c = _controllers[p.id]!;
                final playerName = data.allPlayers.firstWhere((e) => e.id == p.playerId).name;
                final isBankerPlayer = isBanker && p.id == bankerSpId;
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6.0),
                  child: Row(
                    children: [
                      Expanded(
                        flex: 2,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              isBankerPlayer ? '$playerName (Banker)' : playerName,
                              overflow: TextOverflow.ellipsis,
                            ),
                            Text(
                              'Buy-Ins Total: ${_fmtCents(p.buyInCentsTotal)}',
                              style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        flex: 2,
                        child: TextField(
                          controller: c,
                          decoration: const InputDecoration(labelText: 'Cash out'),
                          keyboardType: const TextInputType.numberWithOptions(decimal: true),
                          onChanged: (raw) {
                            _saveDebouncers[p.id!]?.cancel();
                            _saveDebouncers[p.id!] = Timer(const Duration(milliseconds: 400), () {
                              final text = raw.trim();
                              final cents = _parseMoneyToCents(text);
                              ref.read(sessionDetailProvider(widget.sessionId).notifier).updateCashOut(
                                sessionPlayerId: p.id!,
                                cashOutCents: text.isEmpty ? null : cents,
                              );
                            });
                          },
                          onEditingComplete: () {
                            // Format with decimals when done editing
                            final text = c.text.trim();
                            if (text.isNotEmpty && !text.contains('.')) {
                              c.text = '$text.00';
                            }
                          },
                        ),
                      ),
                    ],
                  ),
                );
              }),
              const SizedBox(height: 16),
              const Divider(height: 24),
              Row(
                children: [
                  Icon(Icons.swap_horiz, color: Theme.of(context).colorScheme.primary),
                  const SizedBox(width: 8),
                  const Text('Settlement', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
                  const Spacer(),
                  if (isBanker) ...[
                    ValueListenableBuilder<List<_BankerLine>>(
                      valueListenable: _bankerLinesNotifier,
                      builder: (context, lines, _) {
                        return TextButton.icon(
                          icon: const Icon(Icons.done_all, size: 18),
                          label: const Text('Mark all as settled'),
                          onPressed: lines.isEmpty
                              ? null
                              : () async {
                                  final ok = await showDialog<bool>(
                                    context: context,
                                    builder: (ctx) => AlertDialog(
                                      title: const Text('Confirm'),
                                      content: const Text('Mark all eligible settlements as completed?'),
                                      actions: [
                                        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
                                        FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Confirm')),
                                      ],
                                    ),
                                  );
                                  if (ok == true) {
                                    for (final line in lines) {
                                      if (line.netCents == 0) continue; // skip evens
                                      final sp = data.participants.firstWhere((p) => p.playerId == line.playerId);
                                      if (sp.settlementDone == true) continue;
                                      await ref.read(sessionRepositoryProvider).updateSettlementDone(sessionPlayerId: sp.id!, done: true);
                                    }
                                    ref.invalidate(sessionDetailProvider(widget.sessionId));
                                    if (context.mounted) {
                                      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('All settlements marked done')));
                                    }
                                  }
                                },
                        );
                      },
                    ),
                  ],
                ],
              ),
              const SizedBox(height: 8),
              if (isBanker)
                ValueListenableBuilder<List<_BankerLine>>(
                  valueListenable: _bankerLinesNotifier,
                  builder: (context, bankerLines, _) {
                    if (bankerLines.isEmpty) {
                      return const Text('Enter cash out values to compute settlements.');
                    }
                    return Column(
                      children: [
                        // Banker-centric settlement: losers pay banker, banker pays winners
                        ...bankerLines.map((line) {
                          final sp = data.participants.firstWhere((p) => p.playerId == line.playerId);
                          final name = data.allPlayers.firstWhere((e) => e.id == line.playerId).name;
                          final amount = line.netCents;
                          final isEven = amount == 0;
                          if (amount < 0) {
                            // player pays banker
                            return CheckboxListTile(
                              value: sp.settlementDone,
                              onChanged: isEven
                                  ? null
                                  : (v) async {
                                      await ref.read(sessionRepositoryProvider).updateSettlementDone(sessionPlayerId: sp.id!, done: v ?? false);
                                      ref.invalidate(sessionDetailProvider(widget.sessionId));
                                    },
                              title: Text('$name pays banker'),
                              secondary: const Icon(Icons.arrow_upward, color: Colors.redAccent),
                              controlAffinity: ListTileControlAffinity.trailing,
                              subtitle: Text(_fmtCents(-amount)),
                            );
                          } else if (amount > 0) {
                            // banker pays player
                            return CheckboxListTile(
                              value: sp.settlementDone,
                              onChanged: isEven
                                  ? null
                                  : (v) async {
                                      await ref.read(sessionRepositoryProvider).updateSettlementDone(sessionPlayerId: sp.id!, done: v ?? false);
                                      ref.invalidate(sessionDetailProvider(widget.sessionId));
                                    },
                              title: Text('Banker pays $name'),
                              secondary: const Icon(Icons.arrow_downward, color: Colors.green),
                              controlAffinity: ListTileControlAffinity.trailing,
                              subtitle: Text(_fmtCents(amount)),
                            );
                          } else {
                            return ListTile(
                              leading: const Icon(Icons.horizontal_rule),
                              title: Text('$name is even'),
                            );
                          }
                        }),
                        const Divider(height: 24),
                        // Banker net tile removed per UX request
                      ],
                    );
                  },
                )
              else
                ValueListenableBuilder<List<_Transfer>>(
                  valueListenable: _transfersNotifier,
                  builder: (context, transfers, _) {
                    if (transfers.isEmpty) {
                      return const Text('Enter cash out values to compute settlements.');
                    }
                    return Column(
                      children: transfers.map((t) {
                        final from = data.allPlayers.firstWhere((e) => e.id == t.fromPlayerId).name;
                        final to = data.allPlayers.firstWhere((e) => e.id == t.toPlayerId).name;
                        return ListTile(
                          leading: const Icon(Icons.compare_arrows),
                          title: Text('$from pays $to'),
                          trailing: Text(_fmtCents(t.amountCents)),
                        );
                      }).toList(),
                    );
                  },
                ),
              const Divider(height: 24),
              ListTile(
                leading: const Icon(Icons.calculate),
                title: const Text('Totals'),
                subtitle: Text(isBanker 
                    ? 'Buy-ins: ${_fmtCents(totalBuyIns)}  •  Cash-outs: ${_fmtCents(totalCashOuts)}'
                    : 'Total cash-outs: ${_fmtCents(totalCashOuts)}'),
                trailing: isBanker ? Text(
                  _fmtCents(delta),
                  style: TextStyle(color: delta == 0 ? Colors.green : Colors.orange),
                ) : null,
              ),
            ],
          );
        },
      ),
      // Bottom nav bar only shown when used standalone (not in wizard)
      bottomNavigationBar: widget.showAppBar ? asyncState.whenOrNull(
        data: (data) {
          if (data.session.finalized) return null;
          final allCashedOut = data.participants.isNotEmpty && 
              data.participants.every((p) => p.cashOutCents != null);
          return SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(12.0),
              child: FilledButton.icon(
                icon: Icon(allCashedOut ? Icons.check_circle : Icons.edit),
                label: Text(allCashedOut ? 'Finalize Game' : 'Enter all cash outs to finalize'),
                style: FilledButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  backgroundColor: allCashedOut ? Colors.green : Colors.grey,
                ),
                onPressed: allCashedOut ? () => _finalizeGame(context, data) : null,
              ),
            ),
          );
        },
      ) : null,
    );
  }

  Future<void> _finalizeGame(BuildContext context, SessionDetailState data) async {
    final result = await showDialog<_FinalizeResult?>(
      context: context,
      builder: (dialogContext) => _FinalizeDialog(data: data),
    );
    
    if (result == null) return; // Cancelled
    
    // Finalize the game
    await ref.read(sessionRepositoryProvider).finalizeSession(widget.sessionId);
    ref.invalidate(sessionDetailProvider(widget.sessionId));
    
    // Share to groups if requested
    if (result.shareToGroups && result.selectedGroupIds.isNotEmpty) {
      await ref.read(groupRepositoryProvider).updateSessionGroups(
        widget.sessionId,
        result.selectedGroupIds,
      );
    }
    
    // Share settlement summary if requested
    if (result.shareSummary && context.mounted) {
      final summary = _buildShareText(data);
      await SharePlus.instance.share(ShareParams(text: summary, subject: 'Poker Game Summary'));
    }
    
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Game finalized')),
      );
      // Pop back to home
      Navigator.of(context).popUntil((route) => route.isFirst);
    }
  }

  int _parseMoneyToCents(String input) {
    final cleaned = input.replaceAll(RegExp('[^0-9.,]'), '').replaceAll(',', '.');
    final value = double.tryParse(cleaned) ?? 0.0;
    return (value * 100).round();
  }

  List<_Transfer> _computeSettlement(List<_Balance> balances) {
    final debtors = <_Side>[];
    final creditors = <_Side>[];
    for (final b in balances) {
      if (b.netCents < 0) {
        debtors.add(_Side(playerId: b.playerId, amountCents: -b.netCents));
      } else if (b.netCents > 0) {
        creditors.add(_Side(playerId: b.playerId, amountCents: b.netCents));
      }
    }
    debtors.sort((a, b) => b.amountCents.compareTo(a.amountCents));
    creditors.sort((a, b) => b.amountCents.compareTo(a.amountCents));

    final transfers = <_Transfer>[];
    int i = 0, j = 0;
    while (i < debtors.length && j < creditors.length) {
      final d = debtors[i];
      final c = creditors[j];
      final pay = d.amountCents < c.amountCents ? d.amountCents : c.amountCents;
      transfers.add(_Transfer(fromPlayerId: d.playerId, toPlayerId: c.playerId, amountCents: pay));
      d.amountCents -= pay;
      c.amountCents -= pay;
      if (d.amountCents == 0) i++;
      if (c.amountCents == 0) j++;
    }
    return transfers;
  }

  // Banker settlement: if a player paid upfront, banker pays them their cash-out; else use net (cash - buyins)
  List<_BankerLine> _computeBankerSettlementFromParticipants(List<dynamic> participants, int bankerSessionPlayerId) {
    final lines = <_BankerLine>[];
    for (final dynamic p in participants) {
      if (p.id == bankerSessionPlayerId) continue; // skip banker
      final int cash = p.cashOutCents ?? 0;
      if (p.paidUpfront == true) {
        // Banker pays back the chip value
        lines.add(_BankerLine(playerId: p.playerId, netCents: cash));
      } else {
        final int net = cash - (p.buyInCentsTotal as int);
        lines.add(_BankerLine(playerId: p.playerId, netCents: net));
      }
    }
    return lines;
  }

  String _buildShareText(SessionDetailState detail) {
    final buf = StringBuffer();
    final fmt = NumberFormat.simpleCurrency();
    buf.writeln('Poker Session Summary');
    final isBanker = detail.session.settlementMode == 'banker' && detail.session.bankerSessionPlayerId != null;
    String bankerName = '';
    if (isBanker) {
      final bankerSp = detail.participants.firstWhere((sp) => sp.id == detail.session.bankerSessionPlayerId);
      bankerName = detail.allPlayers.firstWhere((p) => p.id == bankerSp.playerId).name;
    }
    buf.writeln('Mode: ${detail.session.settlementMode}${isBanker ? ' (Banker: $bankerName)' : ''}');
    buf.writeln('');
    buf.writeln('Players:');
    for (final p in detail.participants) {
      final name = detail.allPlayers.firstWhere((e) => e.id == p.playerId).name;
      final buy = fmt.format(p.buyInCentsTotal / 100);
      final cash = fmt.format((p.cashOutCents ?? 0) / 100);
      buf.writeln('- $name: buy-ins $buy, cash-out $cash');
    }
    buf.writeln('');
    // Settlement lines
    final balances = detail.participants
        .map((p) => _Balance(playerId: p.playerId, sessionPlayerId: p.id!, netCents: (p.cashOutCents ?? 0) - p.buyInCentsTotal))
        .toList();
    if (detail.session.settlementMode == 'banker' && detail.session.bankerSessionPlayerId != null) {
      final lines = _computeBankerSettlementFromParticipants(detail.participants, detail.session.bankerSessionPlayerId!);
      buf.writeln('Banker settlement:');
      for (final l in lines) {
        final name = detail.allPlayers.firstWhere((e) => e.id == l.playerId).name;
        if (l.netCents < 0) {
          buf.writeln('- $name pays banker ${fmt.format(-l.netCents / 100)}');
        } else if (l.netCents > 0) {
          buf.writeln('- Banker pays $name ${fmt.format(l.netCents / 100)}');
        } else {
          buf.writeln('- $name is even');
        }
      }
    } else {
      final transfers = _computeSettlement(balances);
      buf.writeln('Pairwise settlement:');
      for (final t in transfers) {
        final from = detail.allPlayers.firstWhere((e) => e.id == t.fromPlayerId).name;
        final to = detail.allPlayers.firstWhere((e) => e.id == t.toPlayerId).name;
        buf.writeln('- $from pays $to ${fmt.format(t.amountCents / 100)}');
      }
    }
    return buf.toString();
  }

  Future<void> _exportCsv() async {
    try {
      final detail = await ref.read(sessionDetailProvider(widget.sessionId).future);
      final rows = <List<dynamic>>[];
      rows.add(['Player', 'Buy-ins', 'Cash-out']);
      for (final p in detail.participants) {
        final name = detail.allPlayers.firstWhere((e) => e.id == p.playerId).name;
        rows.add([name, (p.buyInCentsTotal / 100).toStringAsFixed(2), ((p.cashOutCents ?? 0) / 100).toStringAsFixed(2)]);
      }
      final csvStr = const ListToCsvConverter().convert(rows);
      final dir = await getTemporaryDirectory();
      final file = File(p.join(dir.path, 'poker_session_${detail.session.id ?? ''}.csv'));
      await file.writeAsString(csvStr);
      await SharePlus.instance.share(ShareParams(files: [XFile(file.path)], subject: 'Poker Session CSV'));
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Export failed: $e')));
      }
    }
  }
}

class _Balance {
  final int playerId;
  final int sessionPlayerId;
  final int netCents;
  const _Balance({required this.playerId, required this.sessionPlayerId, required this.netCents});
}

class _Side {
  final int playerId;
  int amountCents;
  _Side({required this.playerId, required this.amountCents});
}

class _Transfer {
  final int fromPlayerId;
  final int toPlayerId;
  final int amountCents;
  const _Transfer({required this.fromPlayerId, required this.toPlayerId, required this.amountCents});
}

class _BankerLine {
  final int playerId;
  final int netCents; // positive -> banker pays player, negative -> player pays banker
  const _BankerLine({required this.playerId, required this.netCents});
}

// Lightweight proxy to pass live-edited participant values into banker settlement computation
class _ParticipantProxy {
  final int id;
  final int playerId;
  final int buyInCentsTotal;
  final int? cashOutCents;
  final bool paidUpfront;
  const _ParticipantProxy({
    required this.id,
    required this.playerId,
    required this.buyInCentsTotal,
    required this.cashOutCents,
    required this.paidUpfront,
  });
}

// Result from finalize dialog
class _FinalizeResult {
  final bool shareToGroups;
  final List<int> selectedGroupIds;
  final bool shareSummary;
  
  const _FinalizeResult({
    required this.shareToGroups,
    required this.selectedGroupIds,
    required this.shareSummary,
  });
}

// Finalize dialog with share options
class _FinalizeDialog extends ConsumerStatefulWidget {
  final SessionDetailState data;
  
  const _FinalizeDialog({required this.data});

  @override
  ConsumerState<_FinalizeDialog> createState() => _FinalizeDialogState();
}

class _FinalizeDialogState extends ConsumerState<_FinalizeDialog> {
  bool _shareToGroups = false;
  bool _shareSummary = false;
  final Set<int> _selectedGroupIds = {};

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final groupsAsync = ref.watch(myGroupsProvider);

    return AlertDialog(
      title: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: Colors.green.withValues(alpha: 0.2),
              shape: BoxShape.circle,
            ),
            child: const Icon(Icons.check_circle, color: Colors.green, size: 28),
          ),
          const SizedBox(width: 12),
          const Text('Finalize Game'),
        ],
      ),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'This will lock the game and mark it complete.',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: Colors.grey.shade600,
              ),
            ),
            const SizedBox(height: 24),
            
            // Share options header
            Text(
              'Share options',
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),
            
            // Share to groups option
            Container(
              decoration: BoxDecoration(
                border: Border.all(color: Colors.grey.shade300),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Column(
                children: [
                  SwitchListTile(
                    title: const Text('Share to groups'),
                    subtitle: const Text('Let group members see this game'),
                    value: _shareToGroups,
                    onChanged: (v) => setState(() => _shareToGroups = v),
                    secondary: const Icon(Icons.group),
                  ),
                  if (_shareToGroups) ...[
                    const Divider(height: 1),
                    groupsAsync.when(
                      loading: () => const Padding(
                        padding: EdgeInsets.all(16),
                        child: Center(child: CircularProgressIndicator()),
                      ),
                      error: (e, _) => Padding(
                        padding: const EdgeInsets.all(16),
                        child: Text('Error loading groups: $e'),
                      ),
                      data: (groups) {
                        if (groups.isEmpty) {
                          return Padding(
                            padding: const EdgeInsets.all(16),
                            child: Text(
                              'No groups yet. Create a group first.',
                              style: TextStyle(color: Colors.grey.shade600),
                            ),
                          );
                        }
                        return Column(
                          children: groups.map((group) => CheckboxListTile(
                            title: Text(group.name),
                            subtitle: Text('${group.memberCount} member${group.memberCount == 1 ? '' : 's'}'),
                            value: _selectedGroupIds.contains(group.id),
                            onChanged: (checked) {
                              setState(() {
                                if (checked == true) {
                                  _selectedGroupIds.add(group.id);
                                } else {
                                  _selectedGroupIds.remove(group.id);
                                }
                              });
                            },
                            dense: true,
                          )).toList(),
                        );
                      },
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 12),
            
            // Share summary option
            Container(
              decoration: BoxDecoration(
                border: Border.all(color: Colors.grey.shade300),
                borderRadius: BorderRadius.circular(12),
              ),
              child: SwitchListTile(
                title: const Text('Share settlement'),
                subtitle: const Text('Send the settlement summary via text/email'),
                value: _shareSummary,
                onChanged: (v) => setState(() => _shareSummary = v),
                secondary: const Icon(Icons.share),
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
        FilledButton.icon(
          style: FilledButton.styleFrom(backgroundColor: Colors.green),
          onPressed: () {
            Navigator.pop(
              context,
              _FinalizeResult(
                shareToGroups: _shareToGroups,
                selectedGroupIds: _selectedGroupIds.toList(),
                shareSummary: _shareSummary,
              ),
            );
          },
          icon: const Icon(Icons.check),
          label: const Text('Finalize'),
        ),
      ],
    );
  }
}
