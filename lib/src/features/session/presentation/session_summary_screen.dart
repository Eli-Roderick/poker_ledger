import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'dart:async';
import 'package:share_plus/share_plus.dart';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'package:csv/csv.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../data/session_detail_providers.dart';
import '../data/session_providers.dart';
import '../../../utils/money.dart';
import '../domain/settlement_engine.dart';

class SessionSummaryScreen extends ConsumerStatefulWidget {
  final int sessionId;
  final bool showAppBar;
  const SessionSummaryScreen({
    super.key,
    required this.sessionId,
    this.showAppBar = true,
  });

  @override
  ConsumerState<SessionSummaryScreen> createState() =>
      _SessionSummaryScreenState();
}

class _SessionSummaryScreenState extends ConsumerState<SessionSummaryScreen> {
  final _controllers = <int, TextEditingController>{};
  // Live settlement computation based on current text fields
  final ValueNotifier<List<_Transfer>> _transfersNotifier =
      ValueNotifier<List<_Transfer>>(<_Transfer>[]);
  final ValueNotifier<List<_BankerLine>> _bankerLinesNotifier =
      ValueNotifier<List<_BankerLine>>(<_BankerLine>[]);
  final Map<int, Timer> _saveDebouncers = <int, Timer>{};
  String? _lastSettlementShadowMismatch;

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

  String _fmtCents(int cents) => Money.formatCents(cents);

  void _formatCashOutField(TextEditingController controller) {
    final text = controller.text.trim();
    if (text.isNotEmpty) {
      // Add decimals if needed
      if (!text.contains('.')) {
        controller.text = '$text.00';
      } else if (text.split('.')[1].length == 1) {
        controller.text = '${text}0';
      }
    }
    // Unfocus to close keyboard
    FocusScope.of(context).unfocus();
    // Clear selection
    controller.selection = TextSelection.collapsed(
      offset: controller.text.length,
    );
  }

  @override
  Widget build(BuildContext context) {
    final asyncState = ref.watch(sessionDetailProvider(widget.sessionId));
    return Scaffold(
      appBar: widget.showAppBar
          ? AppBar(
              title: const Text('Summary'),
              actions: [
                IconButton(
                  tooltip: 'Share summary',
                  icon: const Icon(Icons.share_outlined),
                  onPressed: () async {
                    final detail = await ref.read(
                      sessionDetailProvider(widget.sessionId).future,
                    );
                    final summary = _buildShareText(detail);
                    await SharePlus.instance.share(
                      ShareParams(text: summary, subject: 'Poker Game Summary'),
                    );
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
            )
          : null,
      body: asyncState.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (_, __) =>
            const Center(child: Text('Legacy summary could not be loaded.')),
        data: (data) {
          final participants = data.participants;
          final currentUserId = Supabase.instance.client.auth.currentUser?.id;
          final isReadOnly =
              data.session.finalized ||
              data.session.currentHostId != currentUserId;
          // Prepare controllers
          for (final p in participants) {
            _controllers.putIfAbsent(
              p.id!,
              () => TextEditingController(
                text: p.cashOutCents == null
                    ? ''
                    : (p.cashOutCents! / 100).toStringAsFixed(2),
              ),
            );
          }

          // Helper to compute balances from current text fields (live)
          List<_Balance> computeBalances() {
            return participants.map((p) {
              final raw = _controllers[p.id]!.text.trim();
              final entered = raw.isEmpty
                  ? (p.cashOutCents ?? 0)
                  : _parseMoneyToCents(raw);
              final net =
                  entered -
                  p.buyInCentsTotal; // positive = won, negative = lost
              return _Balance(
                playerId: p.playerId,
                sessionPlayerId: p.id!,
                netCents: net,
              );
            }).toList();
          }

          final isBanker =
              data.session.settlementMode == 'banker' &&
              data.session.bankerSessionPlayerId != null;
          final bankerSpId = data.session.bankerSessionPlayerId;

          void recomputeSettlement() {
            if (isBanker && bankerSpId != null) {
              _bankerLinesNotifier
                  .value = _computeBankerSettlementFromParticipants(
                // synthesize participants with live cash-out values for accurate preview
                participants.map((p) {
                  final raw = _controllers[p.id]!.text.trim();
                  final entered = raw.isEmpty
                      ? p.cashOutCents
                      : _parseMoneyToCents(raw);
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
              _transfersNotifier.value = _computeSettlement(computeBalances());
            }
          }

          // Attach listeners once per controller to update settlement preview
          for (final p in participants) {
            final c = _controllers[p.id]!;
            c.removeListener(recomputeSettlement);
            c.addListener(recomputeSettlement);
          }

          // Initial compute
          recomputeSettlement();
          _shadowComparePersistedSettlement(data);

          // Totals for zero-sum check
          final totalBuyIns = participants.fold<int>(
            0,
            (sum, p) => sum + p.buyInCentsTotal,
          );
          final totalCashOuts = participants.fold<int>(
            0,
            (sum, p) => sum + (p.cashOutCents ?? 0),
          );
          final delta =
              totalCashOuts -
              totalBuyIns; // should be 0 normally (ignoring rake)

          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              if (isReadOnly) ...[
                Card(
                  child: ListTile(
                    leading: const Icon(Icons.lock_outline),
                    title: const Text('Read-only game'),
                    subtitle: Text(
                      data.session.finalized
                          ? 'Finalized games cannot be edited.'
                          : 'Only the game host can edit financial details.',
                    ),
                  ),
                ),
                const SizedBox(height: 12),
              ],
              // Player rows with cash out fields
              ...participants.map((p) {
                final c = _controllers[p.id]!;
                final playerName = data.allPlayers
                    .firstWhere((e) => e.id == p.playerId)
                    .name;
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
                              isBankerPlayer
                                  ? '$playerName (Banker)'
                                  : playerName,
                              overflow: TextOverflow.ellipsis,
                            ),
                            Text(
                              'Buy-Ins Total: ${_fmtCents(p.buyInCentsTotal)}',
                              style: TextStyle(
                                fontSize: 12,
                                color: Colors.grey.shade600,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        flex: 2,
                        child: TextField(
                          controller: c,
                          readOnly: isReadOnly,
                          decoration: const InputDecoration(
                            labelText: 'Cash out',
                          ),
                          keyboardType: const TextInputType.numberWithOptions(
                            decimal: true,
                          ),
                          onChanged: isReadOnly
                              ? null
                              : (raw) {
                                  _saveDebouncers[p.id!]?.cancel();
                                  _saveDebouncers[p.id!] = Timer(
                                    const Duration(milliseconds: 400),
                                    () async {
                                      final text = raw.trim();
                                      final cents = _parseMoneyToCents(text);
                                      try {
                                        await ref
                                            .read(
                                              sessionDetailProvider(
                                                widget.sessionId,
                                              ).notifier,
                                            )
                                            .updateCashOut(
                                              sessionPlayerId: p.id!,
                                              cashOutCents: text.isEmpty
                                                  ? null
                                                  : cents,
                                            );
                                      } catch (_) {
                                        if (context.mounted) {
                                          ScaffoldMessenger.of(
                                            context,
                                          ).showSnackBar(
                                            const SnackBar(
                                              content: Text(
                                                'Cash out was not saved. Please retry.',
                                              ),
                                            ),
                                          );
                                        }
                                      }
                                    },
                                  );
                                },
                          onEditingComplete: () {
                            _formatCashOutField(c);
                            FocusScope.of(context).unfocus();
                          },
                          onTapOutside: (event) {
                            _formatCashOutField(c);
                          },
                          inputFormatters: [
                            FilteringTextInputFormatter.allow(
                              RegExp(r'^\d+(\.\d{0,2})?$'),
                            ),
                          ],
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
                  Icon(
                    Icons.swap_horiz,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                  const SizedBox(width: 8),
                  const Text(
                    'Settlement',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
                  ),
                  const Spacer(),
                  if (isBanker && !isReadOnly) ...[
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
                                      content: const Text(
                                        'Mark all eligible settlements as completed?',
                                      ),
                                      actions: [
                                        TextButton(
                                          onPressed: () =>
                                              Navigator.pop(ctx, false),
                                          child: const Text('Cancel'),
                                        ),
                                        FilledButton(
                                          onPressed: () =>
                                              Navigator.pop(ctx, true),
                                          child: const Text('Confirm'),
                                        ),
                                      ],
                                    ),
                                  );
                                  if (ok == true) {
                                    for (final line in lines) {
                                      if (line.netCents == 0) {
                                        continue; // skip evens
                                      }
                                      final sp = data.participants.firstWhere(
                                        (p) => p.playerId == line.playerId,
                                      );
                                      if (sp.settlementDone == true) continue;
                                      await ref
                                          .read(sessionRepositoryProvider)
                                          .updateSettlementDone(
                                            sessionPlayerId: sp.id!,
                                            done: true,
                                          );
                                    }
                                    ref.invalidate(
                                      sessionDetailProvider(widget.sessionId),
                                    );
                                    if (context.mounted) {
                                      ScaffoldMessenger.of(
                                        context,
                                      ).showSnackBar(
                                        const SnackBar(
                                          content: Text(
                                            'All settlements marked done',
                                          ),
                                        ),
                                      );
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
                      return const Text(
                        'Enter cash out values to compute settlements.',
                      );
                    }
                    return Column(
                      children: [
                        // Banker-centric settlement: losers pay banker, banker pays winners
                        ...bankerLines.map((line) {
                          final sp = data.participants.firstWhere(
                            (p) => p.playerId == line.playerId,
                          );
                          final name = data.allPlayers
                              .firstWhere((e) => e.id == line.playerId)
                              .name;
                          final amount = line.netCents;
                          final isEven = amount == 0;
                          if (amount < 0) {
                            // player pays banker
                            return CheckboxListTile(
                              value: sp.settlementDone,
                              onChanged: isEven || isReadOnly
                                  ? null
                                  : (v) async {
                                      await ref
                                          .read(sessionRepositoryProvider)
                                          .updateSettlementDone(
                                            sessionPlayerId: sp.id!,
                                            done: v ?? false,
                                          );
                                      ref.invalidate(
                                        sessionDetailProvider(widget.sessionId),
                                      );
                                    },
                              title: Text('$name pays banker'),
                              secondary: const Icon(
                                Icons.arrow_upward,
                                color: Colors.redAccent,
                              ),
                              controlAffinity: ListTileControlAffinity.trailing,
                              subtitle: Text(_fmtCents(-amount)),
                            );
                          } else if (amount > 0) {
                            // banker pays player
                            return CheckboxListTile(
                              value: sp.settlementDone,
                              onChanged: isEven || isReadOnly
                                  ? null
                                  : (v) async {
                                      await ref
                                          .read(sessionRepositoryProvider)
                                          .updateSettlementDone(
                                            sessionPlayerId: sp.id!,
                                            done: v ?? false,
                                          );
                                      ref.invalidate(
                                        sessionDetailProvider(widget.sessionId),
                                      );
                                    },
                              title: Text('Banker pays $name'),
                              secondary: const Icon(
                                Icons.arrow_downward,
                                color: Colors.green,
                              ),
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
                      return const Text(
                        'Enter cash out values to compute settlements.',
                      );
                    }
                    return Column(
                      children: transfers.map((t) {
                        final from = data.allPlayers
                            .firstWhere((e) => e.id == t.fromPlayerId)
                            .name;
                        final to = data.allPlayers
                            .firstWhere((e) => e.id == t.toPlayerId)
                            .name;
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
              // Buy-ins / Cash-outs / Difference summary widget
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: delta == 0
                      ? Colors.green.withValues(alpha: 0.1)
                      : Colors.orange.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: delta == 0
                        ? Colors.green.withValues(alpha: 0.3)
                        : Colors.orange.withValues(alpha: 0.3),
                  ),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Buy-ins',
                            style: Theme.of(context).textTheme.labelSmall
                                ?.copyWith(color: Colors.grey.shade600),
                          ),
                          Text(
                            _fmtCents(totalBuyIns),
                            style: Theme.of(context).textTheme.titleMedium
                                ?.copyWith(fontWeight: FontWeight.w600),
                          ),
                        ],
                      ),
                    ),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Cash-outs',
                            style: Theme.of(context).textTheme.labelSmall
                                ?.copyWith(color: Colors.grey.shade600),
                          ),
                          Text(
                            _fmtCents(totalCashOuts),
                            style: Theme.of(context).textTheme.titleMedium
                                ?.copyWith(fontWeight: FontWeight.w600),
                          ),
                        ],
                      ),
                    ),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Text(
                          delta == 0 ? 'Balanced' : 'Off by',
                          style: Theme.of(context).textTheme.labelSmall
                              ?.copyWith(
                                color: delta == 0
                                    ? Colors.green
                                    : Colors.orange,
                              ),
                        ),
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              delta == 0
                                  ? Icons.check_circle
                                  : Icons.warning_amber_rounded,
                              size: 18,
                              color: delta == 0 ? Colors.green : Colors.orange,
                            ),
                            const SizedBox(width: 4),
                            Text(
                              delta == 0 ? '\$0.00' : _fmtCents(delta.abs()),
                              style: Theme.of(context).textTheme.titleMedium
                                  ?.copyWith(
                                    fontWeight: FontWeight.w600,
                                    color: delta == 0
                                        ? Colors.green
                                        : Colors.orange,
                                  ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          );
        },
      ),
      // Bottom nav bar only shown when used standalone (not in wizard)
      bottomNavigationBar: widget.showAppBar
          ? asyncState.whenOrNull(
              data: (data) {
                final currentUserId =
                    Supabase.instance.client.auth.currentUser?.id;
                if (data.session.finalized ||
                    data.session.currentHostId != currentUserId) {
                  return null;
                }
                final allCashedOut =
                    data.participants.isNotEmpty &&
                    data.participants.every((p) => p.cashOutCents != null);
                final totalBuyIns = data.participants.fold<int>(
                  0,
                  (sum, participant) => sum + participant.buyInCentsTotal,
                );
                final totalCashOuts = data.participants.fold<int>(
                  0,
                  (sum, participant) => sum + (participant.cashOutCents ?? 0),
                );
                final isBalanced = totalBuyIns == totalCashOuts;
                final canFinalize = allCashedOut && isBalanced;
                return SafeArea(
                  child: Padding(
                    padding: const EdgeInsets.all(12.0),
                    child: FilledButton.icon(
                      icon: Icon(canFinalize ? Icons.check_circle : Icons.edit),
                      label: Text(
                        !allCashedOut
                            ? 'Enter all cash outs to finalize'
                            : !isBalanced
                            ? 'Resolve ${_fmtCents((totalCashOuts - totalBuyIns).abs())} difference'
                            : 'Finalize Game',
                      ),
                      style: FilledButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        backgroundColor: canFinalize
                            ? Colors.green
                            : Colors.grey,
                      ),
                      onPressed: canFinalize
                          ? () => _finalizeGame(context, data)
                          : null,
                    ),
                  ),
                );
              },
            )
          : null,
    );
  }

  Future<void> _finalizeGame(
    BuildContext context,
    SessionDetailState data,
  ) async {
    final result = await showDialog<_FinalizeResult?>(
      context: context,
      builder: (dialogContext) => _FinalizeDialog(data: data),
    );

    if (result == null) return; // Cancelled

    // Finalize the game
    await ref.read(sessionRepositoryProvider).finalizeSession(widget.sessionId);
    ref.invalidate(sessionDetailProvider(widget.sessionId));

    // Share settlement summary if requested
    if (result.shareSummary && context.mounted) {
      final summary = _buildShareText(data);
      await SharePlus.instance.share(
        ShareParams(text: summary, subject: 'Poker Game Summary'),
      );
    }

    if (context.mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Game finalized')));
      // Pop back to home
      Navigator.of(context).popUntil((route) => route.isFirst);
    }
  }

  int _parseMoneyToCents(String input) {
    return Money.tryParseCents(input) ?? 0;
  }

  void _shadowComparePersistedSettlement(SessionDetailState detail) {
    if (detail.participants.isEmpty ||
        detail.participants.any(
          (participant) => participant.cashOutCents == null,
        )) {
      return;
    }
    final totalNet = detail.participants.fold<int>(
      0,
      (sum, participant) =>
          sum + participant.cashOutCents! - participant.buyInCentsTotal,
    );
    if (totalNet != 0) return;

    String? mismatch;
    if (detail.session.settlementMode == 'banker' &&
        detail.session.bankerSessionPlayerId != null) {
      final banker = detail.participants.firstWhere(
        (participant) => participant.id == detail.session.bankerSessionPlayerId,
      );
      final canonical = SettlementEngine.settleBanker(
        participants: detail.participants.map(
          (participant) => BankerSettlementParticipant(
            participantId: participant.playerId,
            buyInCents: participant.buyInCentsTotal,
            cashOutCents: participant.cashOutCents!,
            paidUpfront: participant.paidUpfront,
          ),
        ),
        bankerParticipantId: banker.playerId,
      );
      final canonicalLines = <int, int>{};
      for (final transfer in canonical.transfers) {
        if (transfer.fromParticipantId == banker.playerId) {
          canonicalLines[transfer.toParticipantId] = transfer.amountCents;
        } else {
          canonicalLines[transfer.fromParticipantId] = -transfer.amountCents;
        }
      }
      final legacyLines = {
        for (final line in _computeBankerSettlementFromParticipants(
          detail.participants,
          detail.session.bankerSessionPlayerId!,
        ))
          if (line.netCents != 0) line.playerId: line.netCents,
      };
      if (!_mapsEqual(canonicalLines, legacyLines)) {
        mismatch =
            'banker totals differ: canonical=$canonicalLines legacy=$legacyLines';
      }
    } else {
      final balances = detail.participants
          .map(
            (participant) => SettlementBalance(
              participantId: participant.playerId,
              netCents: participant.cashOutCents! - participant.buyInCentsTotal,
            ),
          )
          .toList();
      final canonical = SettlementEngine.settlePairwise(balances);
      final legacy = _computeSettlement(
        detail.participants
            .map(
              (participant) => _Balance(
                playerId: participant.playerId,
                sessionPlayerId: participant.id!,
                netCents:
                    participant.cashOutCents! - participant.buyInCentsTotal,
              ),
            )
            .toList(),
      );
      final canonicalGraph = canonical.transfers
          .map(
            (transfer) =>
                '${transfer.fromParticipantId}>${transfer.toParticipantId}:${transfer.amountCents}',
          )
          .toList();
      final legacyGraph = legacy
          .map(
            (transfer) =>
                '${transfer.fromPlayerId}>${transfer.toPlayerId}:${transfer.amountCents}',
          )
          .toList();
      if (!_listsEqual(canonicalGraph, legacyGraph)) {
        mismatch =
            'pairwise graph differs: canonical=$canonicalGraph legacy=$legacyGraph';
      }
    }

    final fingerprint = mismatch == null
        ? null
        : 'session=${detail.session.id};engine=${SettlementEngine.version};$mismatch';
    if (fingerprint != null && fingerprint != _lastSettlementShadowMismatch) {
      _lastSettlementShadowMismatch = fingerprint;
      debugPrint('Settlement shadow mismatch: $fingerprint');
    }
  }

  bool _mapsEqual(Map<int, int> first, Map<int, int> second) {
    if (first.length != second.length) return false;
    return first.entries.every((entry) => second[entry.key] == entry.value);
  }

  bool _listsEqual(List<String> first, List<String> second) {
    if (first.length != second.length) return false;
    for (var index = 0; index < first.length; index++) {
      if (first[index] != second[index]) return false;
    }
    return true;
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
      transfers.add(
        _Transfer(
          fromPlayerId: d.playerId,
          toPlayerId: c.playerId,
          amountCents: pay,
        ),
      );
      d.amountCents -= pay;
      c.amountCents -= pay;
      if (d.amountCents == 0) i++;
      if (c.amountCents == 0) j++;
    }
    return transfers;
  }

  // Banker settlement: if a player paid upfront, banker pays them their cash-out; else use net (cash - buyins)
  List<_BankerLine> _computeBankerSettlementFromParticipants(
    List<dynamic> participants,
    int bankerSessionPlayerId,
  ) {
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
    final isBanker =
        detail.session.settlementMode == 'banker' &&
        detail.session.bankerSessionPlayerId != null;
    String bankerName = '';
    if (isBanker) {
      final bankerSp = detail.participants.firstWhere(
        (sp) => sp.id == detail.session.bankerSessionPlayerId,
      );
      bankerName = detail.allPlayers
          .firstWhere((p) => p.id == bankerSp.playerId)
          .name;
    }
    buf.writeln(
      'Mode: ${detail.session.settlementMode}${isBanker ? ' (Banker: $bankerName)' : ''}',
    );
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
        .map(
          (p) => _Balance(
            playerId: p.playerId,
            sessionPlayerId: p.id!,
            netCents: (p.cashOutCents ?? 0) - p.buyInCentsTotal,
          ),
        )
        .toList();
    if (detail.session.settlementMode == 'banker' &&
        detail.session.bankerSessionPlayerId != null) {
      final lines = _computeBankerSettlementFromParticipants(
        detail.participants,
        detail.session.bankerSessionPlayerId!,
      );
      buf.writeln('Banker settlement:');
      for (final l in lines) {
        final name = detail.allPlayers
            .firstWhere((e) => e.id == l.playerId)
            .name;
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
        final from = detail.allPlayers
            .firstWhere((e) => e.id == t.fromPlayerId)
            .name;
        final to = detail.allPlayers
            .firstWhere((e) => e.id == t.toPlayerId)
            .name;
        buf.writeln('- $from pays $to ${fmt.format(t.amountCents / 100)}');
      }
    }
    return buf.toString();
  }

  Future<void> _exportCsv() async {
    try {
      final detail = await ref.read(
        sessionDetailProvider(widget.sessionId).future,
      );
      final rows = <List<dynamic>>[];
      rows.add(['Player', 'Buy-ins', 'Cash-out']);
      for (final p in detail.participants) {
        final name = detail.allPlayers
            .firstWhere((e) => e.id == p.playerId)
            .name;
        rows.add([
          name,
          (p.buyInCentsTotal / 100).toStringAsFixed(2),
          ((p.cashOutCents ?? 0) / 100).toStringAsFixed(2),
        ]);
      }
      final csvStr = const ListToCsvConverter().convert(rows);
      final dir = await getTemporaryDirectory();
      final file = File(
        p.join(dir.path, 'poker_session_${detail.session.id ?? ''}.csv'),
      );
      await file.writeAsString(csvStr);
      await SharePlus.instance.share(
        ShareParams(files: [XFile(file.path)], subject: 'Poker Session CSV'),
      );
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('The CSV could not be exported.')),
        );
      }
    }
  }
}

class _Balance {
  final int playerId;
  final int sessionPlayerId;
  final int netCents;
  const _Balance({
    required this.playerId,
    required this.sessionPlayerId,
    required this.netCents,
  });
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
  const _Transfer({
    required this.fromPlayerId,
    required this.toPlayerId,
    required this.amountCents,
  });
}

class _BankerLine {
  final int playerId;
  final int
  netCents; // positive -> banker pays player, negative -> player pays banker
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
  final bool shareSummary;

  const _FinalizeResult({required this.shareSummary});
}

// Finalize dialog with share options
class _FinalizeDialog extends ConsumerStatefulWidget {
  final SessionDetailState data;

  const _FinalizeDialog({required this.data});

  @override
  ConsumerState<_FinalizeDialog> createState() => _FinalizeDialogState();
}

class _FinalizeDialogState extends ConsumerState<_FinalizeDialog> {
  bool _shareSummary = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: Colors.green.withValues(alpha: 0.2),
              shape: BoxShape.circle,
            ),
            child: const Icon(
              Icons.check_circle,
              color: Colors.green,
              size: 28,
            ),
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

            // Share summary option
            Container(
              decoration: BoxDecoration(
                border: Border.all(color: Colors.grey.shade300),
                borderRadius: BorderRadius.circular(12),
              ),
              child: SwitchListTile(
                title: const Text('Share settlement'),
                subtitle: const Text(
                  'Send the settlement summary via text/email',
                ),
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
              _FinalizeResult(shareSummary: _shareSummary),
            );
          },
          icon: const Icon(Icons.check),
          label: const Text('Finalize'),
        ),
      ],
    );
  }
}
