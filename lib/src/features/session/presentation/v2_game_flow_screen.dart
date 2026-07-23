import 'dart:async';

import 'package:csv/csv.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import 'package:share_plus/share_plus.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../utils/money.dart';
import '../data/sessions_list_providers.dart';
import '../data/v2_game_providers.dart';
import '../domain/v2_game_models.dart';
import '../domain/settlement_engine.dart';
import 'game_invitations_sheet.dart';
import 'v2_invite_sheet.dart';

const _kSilentHostReason = 'Host action';

class V2GameFlowScreen extends ConsumerStatefulWidget {
  final int sessionId;

  const V2GameFlowScreen({super.key, required this.sessionId});

  @override
  ConsumerState<V2GameFlowScreen> createState() => _V2GameFlowScreenState();
}

class _V2GameFlowScreenState extends ConsumerState<V2GameFlowScreen> {
  bool _showSummary = false;
  bool _summaryUnlocked = false;
  int? _navStep;
  String? _lastJoinCode;
  bool _busy = false;
  int _inflightWrites = 0;
  Future<void> _writeChain = Future<void>.value();
  String? _operationError;
  RealtimeChannel? _gameChannel;
  Timer? _detailInvalidateDebounce;
  DateTime? _suppressRemoteInvalidateUntil;

  @override
  void initState() {
    super.initState();
    _subscribeToGameRealtime();
  }

  @override
  void dispose() {
    _detailInvalidateDebounce?.cancel();
    final channel = _gameChannel;
    _gameChannel = null;
    if (channel != null) {
      Supabase.instance.client.removeChannel(channel);
    }
    super.dispose();
  }

  void _scheduleDetailInvalidate({bool force = false}) {
    if (!force &&
        _suppressRemoteInvalidateUntil != null &&
        DateTime.now().isBefore(_suppressRemoteInvalidateUntil!)) {
      return;
    }
    _detailInvalidateDebounce?.cancel();
    _detailInvalidateDebounce = Timer(const Duration(milliseconds: 200), () {
      if (!mounted) return;
      ref.invalidate(v2GameDetailProvider(widget.sessionId));
    });
  }

  void _subscribeToGameRealtime() {
    final client = Supabase.instance.client;
    final sessionId = widget.sessionId;
    _gameChannel = client
        .channel('game-sync-$sessionId')
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'game_invitations',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'session_id',
            value: sessionId,
          ),
          callback: (_) => _scheduleDetailInvalidate(),
        )
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'session_players',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'session_id',
            value: sessionId,
          ),
          callback: (_) => _scheduleDetailInvalidate(),
        )
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'ledger_events',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'session_id',
            value: sessionId,
          ),
          callback: (_) => _scheduleDetailInvalidate(),
        )
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'sessions',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'id',
            value: sessionId,
          ),
          callback: (_) => _scheduleDetailInvalidate(),
        )
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'settlement_transfers',
          callback: (_) => _scheduleDetailInvalidate(),
        )
        .subscribe();
  }

  Future<void> _refreshDetail() async {
    ref.invalidate(v2GameDetailProvider(widget.sessionId));
    await ref.read(v2GameDetailProvider(widget.sessionId).future);
  }

  Future<bool> _run(Future<void> Function() action) {
    final completer = Completer<bool>();
    _writeChain = _writeChain
        .then((_) async {
          if (!mounted) {
            completer.complete(false);
            return;
          }
          setState(() {
            _inflightWrites += 1;
            _busy = true;
            _operationError = null;
          });
          try {
            await action();
            // Coalesce with realtime: local invalidate now, suppress echo briefly.
            _suppressRemoteInvalidateUntil = DateTime.now().add(
              const Duration(milliseconds: 400),
            );
            ref.invalidate(v2GameDetailProvider(widget.sessionId));
            completer.complete(true);
          } catch (error) {
            if (kDebugMode) {
              debugPrint('V2 game op failed: $error');
            }
            if (mounted) {
              setState(() => _operationError = _friendlyError(error));
            }
            completer.complete(false);
          } finally {
            if (mounted) {
              setState(() {
                _inflightWrites = (_inflightWrites - 1).clamp(0, 1000);
                _busy = _inflightWrites > 0;
              });
            }
          }
        })
        .catchError((Object _) {});
    return completer.future;
  }

  @override
  Widget build(BuildContext context) {
    final detailAsync = ref.watch(v2GameDetailProvider(widget.sessionId));
    final appBarDetail = detailAsync.valueOrNull;
    return Scaffold(
      appBar: AppBar(
        title: detailAsync.maybeWhen(
          data: (detail) => Text(
            detail.game.name?.trim().isNotEmpty == true
                ? detail.game.name!
                : 'Poker game',
          ),
          orElse: () => const Text('Poker game'),
        ),
        actions: [
          if (appBarDetail != null &&
              appBarDetail.game.canEdit &&
              (appBarDetail.game.isDraft || appBarDetail.game.isLive) &&
              !appBarDetail.game.isFinalized &&
              appBarDetail.game.phase != 'cancelled') ...[
            Builder(
              builder: (context) {
                final pendingCount = appBarDetail.invitations
                    .where((invitation) => invitation.awaitingHost)
                    .length;
                return IconButton(
                  tooltip: 'Join requests',
                  onPressed: () => _showHostJoinRequests(appBarDetail),
                  icon: Badge(
                    isLabelVisible: pendingCount > 0,
                    label: Text('$pendingCount'),
                    child: const Icon(Icons.notifications_outlined),
                  ),
                );
              },
            ),
            IconButton(
              tooltip: 'Invite players',
              onPressed: () => _openInviteSheet(appBarDetail),
              icon: const Icon(Icons.share),
            ),
          ],
          if (appBarDetail != null)
            PopupMenuButton<_AppBarMenuAction>(
              tooltip: 'More',
              onSelected: (action) {
                switch (action) {
                  case _AppBarMenuAction.refresh:
                    ref.invalidate(v2GameDetailProvider(widget.sessionId));
                  case _AppBarMenuAction.inviteByHandle:
                    _showInviteSearch(appBarDetail);
                  case _AppBarMenuAction.cancelGame:
                    _cancelGame(appBarDetail);
                  case _AppBarMenuAction.leaveGame:
                    _leaveGame(appBarDetail);
                }
              },
              itemBuilder: (context) {
                final me = ref.read(v2GameRepositoryProvider).currentUserId;
                final canLeave =
                    appBarDetail.game.isDraft &&
                    !appBarDetail.game.canEdit &&
                    appBarDetail.participants.any(
                      (participant) => participant.profileId == me,
                    );
                return [
                  const PopupMenuItem(
                    value: _AppBarMenuAction.refresh,
                    child: Text('Refresh'),
                  ),
                  if (appBarDetail.game.canEdit &&
                      (appBarDetail.game.isDraft || appBarDetail.game.isLive) &&
                      !appBarDetail.game.isFinalized &&
                      appBarDetail.game.phase != 'cancelled')
                    const PopupMenuItem(
                      value: _AppBarMenuAction.inviteByHandle,
                      child: Text('Invite by handle'),
                    ),
                  if (canLeave)
                    const PopupMenuItem(
                      value: _AppBarMenuAction.leaveGame,
                      child: Text('Leave game'),
                    ),
                  if (appBarDetail.game.canEdit &&
                      !appBarDetail.game.isFinalized &&
                      appBarDetail.game.phase != 'cancelled')
                    const PopupMenuItem(
                      value: _AppBarMenuAction.cancelGame,
                      child: Text('Cancel game'),
                    ),
                ];
              },
            ),
        ],
      ),
      body: detailAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => _ErrorState(
          message: _friendlyError(error),
          onRetry: () => ref.invalidate(v2GameDetailProvider(widget.sessionId)),
        ),
        data: (detail) {
          final repository = ref.read(v2GameRepositoryProvider);
          final isHost = detail.game.canEdit;
          final summaryUnlocked = _summaryUnlockedFor(detail.game);
          final visibleStep = _visibleStepFor(detail.game, summaryUnlocked);
          final highestReached = _highestReachedFor(
            detail.game,
            summaryUnlocked,
          );
          return Column(
            children: [
              _GameProgress(
                currentStep: visibleStep,
                highestReached: highestReached,
                game: detail.game,
                summaryUnlocked: summaryUnlocked,
                onStepPressed: (step) =>
                    _onProgressStepPressed(detail, step, summaryUnlocked),
              ),
              if (_busy) const LinearProgressIndicator(minHeight: 2),
              if (_operationError != null)
                Semantics(
                  liveRegion: true,
                  child: Container(
                    width: double.infinity,
                    color: Theme.of(context).colorScheme.errorContainer,
                    padding: const EdgeInsets.all(12),
                    child: Row(
                      children: [
                        Icon(
                          Icons.sync_problem,
                          color: Theme.of(context).colorScheme.onErrorContainer,
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            'Not saved — $_operationError Retry the action.',
                            style: TextStyle(
                              color: Theme.of(
                                context,
                              ).colorScheme.onErrorContainer,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              Expanded(
                child: switch (visibleStep) {
                  0 => _LobbyPage(
                    detail: detail,
                    isHost: isHost,
                    currentUserId: repository.currentUserId,
                    showStartBar: detail.game.isDraft,
                    onRefresh: _refreshDetail,
                    onInviteByHandle: () => _showInviteSearch(detail),
                    onSetBackup: (participant) => _run(
                      () => repository.setBackupHost(
                        widget.sessionId,
                        participant.profileId!,
                      ),
                    ),
                    onBuyInSaved: detail.game.isDraft
                        ? (participant, cents) => _run(
                            () => repository.setBuyIn(
                              sessionId: widget.sessionId,
                              participantId: participant.id,
                              amountCents: cents,
                            ),
                          )
                        : null,
                    onStartGame: detail.participants.length >= 2 && isHost
                        ? () => _run(
                            () => repository.startGame(
                              sessionId: widget.sessionId,
                              settlementMode: 'pairwise',
                              bankerParticipantId: null,
                            ),
                          )
                        : null,
                    onLeave: detail.game.isDraft && !isHost
                        ? () => _leaveGame(detail)
                        : null,
                    onRemoveParticipant: isHost && detail.game.isDraft
                        ? (participant) => _removeParticipant(detail, participant)
                        : null,
                  ),
                  1 => _LivePage(
                    detail: detail,
                    isHost: isHost,
                    onRefresh: _refreshDetail,
                    onRebuy: (participant) => _recordRebuy(participant),
                    onDeleteEvent: (event) => _deleteLedgerEvent(event),
                    onInvite: () => _openInviteSheet(detail),
                    onReview: () => _reviewGame(detail, isHost),
                    onRemoveParticipant: isHost && detail.game.isLive
                        ? (participant) => _removeParticipant(detail, participant)
                        : null,
                    onToggleOut: isHost && detail.game.isLive
                        ? _toggleParticipantOut
                        : null,
                  ),
                  _ => _SummaryPage(
                    detail: detail,
                    isHost: isHost,
                    onRefresh: _refreshDetail,
                    onCashOutSaved: isHost && detail.game.isSettling
                        ? _saveCashOut
                        : null,
                    onFinalize:
                        detail.everyPlayerCashedOut &&
                            detail.ledgerBalanceCents == 0 &&
                            isHost &&
                            detail.game.isSettling
                        ? () => _confirmFinalize(detail)
                        : null,
                    onShare: () => _shareSummary(detail),
                    onExport: () => _shareCsv(detail),
                    onPdf: () => _sharePdf(detail),
                    currentUserId: repository.currentUserId,
                    onTransferStatus: (transfer, status) => _run(
                      () =>
                          repository.updateTransferStatus(transfer.id, status),
                    ),
                    onCorrect: detail.game.isFinalized && isHost
                        ? () => _correctFinalized(detail)
                        : null,
                    onRemoveParticipant: isHost && detail.game.isSettling
                        ? (participant) => _removeParticipant(detail, participant)
                        : null,
                    onSettlementPreferencesChanged: isHost &&
                            !detail.game.isFinalized &&
                            (detail.game.isLive || detail.game.isSettling)
                        ? ({
                            required String settlementMode,
                            required int? bankerParticipantId,
                            required Set<int> paidUpfrontParticipantIds,
                          }) => _run(
                            () => repository.setSettlementPreferences(
                              sessionId: widget.sessionId,
                              settlementMode: settlementMode,
                              bankerParticipantId: bankerParticipantId,
                              paidUpfrontParticipantIds:
                                  paidUpfrontParticipantIds,
                            ),
                          )
                        : null,
                  ),
                },
              ),
            ],
          );
        },
      ),
    );
  }

  bool _summaryUnlockedFor(V2Game game) {
    return _summaryUnlocked ||
        game.isSettling ||
        game.isFinalized ||
        (!game.isDraft && !game.isLive && game.phase != 'cancelled');
  }

  int _highestReachedFor(V2Game game, bool summaryUnlocked) {
    if (game.isDraft) return 0;
    if (game.isFinalized) return 2;
    return 1;
  }

  int _visibleStepFor(V2Game game, bool summaryUnlocked) {
    if (game.isDraft) return 0;
    final override = _navStep;
    if (override != null) {
      if (override == 0) return 0;
      if (override == 1 && (game.isLive || game.isSettling)) return 1;
      if (override == 2 && summaryUnlocked) return 2;
    }
    if (game.isLive) return _showSummary && summaryUnlocked ? 2 : 1;
    return 2;
  }

  Future<void> _onProgressStepPressed(
    V2GameDetail detail,
    int step,
    bool summaryUnlocked,
  ) async {
    final game = detail.game;
    if (game.isDraft) return;

    if (step == 0) {
      setState(() {
        _navStep = 0;
        _showSummary = false;
      });
      return;
    }

    if (step == 1) {
      if (game.isSettling && game.canEdit) {
        await _returnToLive();
        return;
      }
      if (game.isLive || game.isSettling) {
        setState(() {
          _navStep = 1;
          _showSummary = false;
        });
      }
      return;
    }

    if (step == 2 && summaryUnlocked) {
      setState(() {
        _navStep = 2;
        _showSummary = true;
      });
    }
  }

  Future<void> _openInviteSheet(V2GameDetail detail) async {
    final gameName = detail.game.name?.trim().isNotEmpty == true
        ? detail.game.name!
        : 'Poker game';
    await showV2InviteSheet(
      context: context,
      gameName: gameName,
      initialCode: _lastJoinCode,
      ensureJoinCode: ({required bool regenerate}) async {
        final result = await ref
            .read(v2GameRepositoryProvider)
            .createJoinCode(widget.sessionId);
        final code = result['code'] as String?;
        if (code != null && mounted) {
          setState(() => _lastJoinCode = code);
        }
        return code;
      },
    );
  }

  Future<void> _showHostJoinRequests(V2GameDetail detail) async {
    final joinRequests = detail.invitations
        .where((invitation) => invitation.awaitingHost)
        .toList();
    await showHostJoinRequestsSheet(
      context: context,
      joinRequests: joinRequests,
      onRespond: (id, accept) async {
        await _run(
          () => ref
              .read(v2GameRepositoryProvider)
              .respondToInvitation(id, accept),
        );
      },
    );
  }

  Future<void> _showInviteSearch(V2GameDetail detail) async {
    final repository = ref.read(v2GameRepositoryProvider);
    final selected = await showModalBottomSheet<DiscoverableProfile>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _ProfileSearchSheet(
        search: (query) =>
            repository.searchProfiles(query, sessionId: widget.sessionId),
      ),
    );
    if (selected != null) {
      await _run(() => repository.inviteProfile(widget.sessionId, selected.id));
    }
  }

  Future<void> _recordRebuy(V2Participant participant) async {
    final amount = await showDialog<int>(
      context: context,
      builder: (_) =>
          _MoneyDialog(title: 'Rebuy for ${participant.displayName}'),
    );
    if (amount == null) return;
    await _run(
      () => ref
          .read(v2GameRepositoryProvider)
          .addRebuy(
            sessionId: widget.sessionId,
            participantId: participant.id,
            amountCents: amount,
          ),
    );
  }

  Future<bool> _saveCashOut(V2Participant participant, int amountCents) async {
    if (amountCents < 0) return false;
    return _run(
      () => ref
          .read(v2GameRepositoryProvider)
          .setCashOut(
            sessionId: widget.sessionId,
            participantId: participant.id,
            amountCents: amountCents,
          ),
    );
  }

  Future<void> _toggleParticipantOut(V2Participant participant) async {
    await _run(
      () => ref
          .read(v2GameRepositoryProvider)
          .setParticipantEliminated(
            sessionId: widget.sessionId,
            participantId: participant.id,
            eliminated: !participant.isOut,
          ),
    );
  }

  Future<void> _deleteLedgerEvent(V2LedgerEvent event) async {
    if (event.type != 'rebuy' && event.type != 'cash_out') return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Remove this entry?'),
        content: const Text(
          'This removes the entry from the game before finalization.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await _run(
      () => ref
          .read(v2GameRepositoryProvider)
          .deleteLedgerEvent(
            sessionId: widget.sessionId,
            eventId: event.id,
          ),
    );
  }

  Future<void> _reviewGame(V2GameDetail detail, bool isHost) async {
    if (isHost && detail.game.isLive) {
      final advanced = await _run(
        () => ref
            .read(v2GameRepositoryProvider)
            .beginSettlement(widget.sessionId),
      );
      if (!advanced) return;
    }
    if (mounted) {
      setState(() {
        _summaryUnlocked = true;
        _showSummary = true;
        _navStep = 2;
      });
    }
  }

  Future<void> _returnToLive() async {
    final returned = await _run(
      () => ref
          .read(v2GameRepositoryProvider)
          .returnToLive(widget.sessionId, _kSilentHostReason),
    );
    if (returned && mounted) {
      setState(() {
        _summaryUnlocked = true;
        _showSummary = false;
        _navStep = 1;
      });
    }
  }

  Future<void> _confirmFinalize(V2GameDetail detail) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Finalize this game?'),
        content: const Text(
          'The ledger and settlement will be saved as an auditable revision. '
          'Later corrections create a new revision and require a reason.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Keep reviewing'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Finalize'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await _run(
        () => ref.read(v2GameRepositoryProvider).finalizeGame(detail.game.id),
      );
    }
  }

  Future<void> _shareSummary(V2GameDetail detail) async {
    final buffer = StringBuffer('${detail.game.name ?? 'Poker game'}\n');
    buffer.writeln(
      '${detail.game.settlementMode} settlement · '
      'revision ${detail.game.latestRevisionId ?? 'preview'}',
    );
    for (final participant in detail.participants) {
      final totals = detail.totalsFor(participant.id);
      buffer.writeln(
        '${participant.displayName}: '
        '${Money.formatCents(totals.netCents, symbol: '\$')} net',
      );
    }
    if (detail.transfers.isNotEmpty) {
      buffer.writeln('\nSettlement:');
      for (final transfer in detail.transfers) {
        final from = detail.participants.firstWhere(
          (item) => item.id == transfer.fromParticipantId,
        );
        final to = detail.participants.firstWhere(
          (item) => item.id == transfer.toParticipantId,
        );
        buffer.writeln(
          '${from.displayName} pays ${to.displayName} '
          '${Money.formatCents(transfer.amountCents, symbol: '\$')} '
          '(${transfer.status})',
        );
      }
    }
    await SharePlus.instance.share(ShareParams(text: buffer.toString()));
  }

  Future<void> _shareCsv(V2GameDetail detail) async {
    final rows = <List<Object?>>[
      ['Poker Ledger game export'],
      ['Session ID', detail.game.id],
      ['Ledger version', 2],
      ['Phase', detail.game.phase],
      ['Revision ID', detail.game.latestRevisionId],
      ['Settlement mode', detail.game.settlementMode],
      [],
      ['Participant snapshot', 'Buy-ins cents', 'Cash-out cents', 'Net cents'],
      ...detail.participants.map((participant) {
        final totals = detail.totalsFor(participant.id);
        return [
          participant.displayName,
          totals.buyInsCents,
          totals.cashOutCents,
          totals.netCents,
        ];
      }),
      [],
      [
        'Event sequence',
        'Participant snapshot',
        'Type',
        'Signed cents',
        'Actor snapshot',
        'Reason',
        'Reverses event',
        'Created at',
      ],
      ...detail.events.map((event) {
        final participant = detail.participants.firstWhere(
          (item) => item.id == event.participantId,
        );
        return [
          event.sequence,
          participant.displayName,
          event.type,
          event.amountCents,
          event.actorSnapshot,
          event.reason,
          event.reversesEventId,
          event.createdAt.toIso8601String(),
        ];
      }),
      [],
      [
        'Revision',
        'Through event',
        'Mode',
        'Buy-ins cents',
        'Cash-outs cents',
        'Reason',
        'Created at',
        'Superseded at',
      ],
      ...detail.revisions.map(
        (revision) => [
          revision.revisionNumber,
          revision.throughEventSequence,
          revision.settlementMode,
          revision.totalBuyInCents,
          revision.totalCashOutCents,
          revision.reason,
          revision.createdAt.toIso8601String(),
          revision.supersededAt?.toIso8601String(),
        ],
      ),
      [],
      ['Payer snapshot', 'Recipient snapshot', 'Amount cents', 'Status'],
      ...detail.transfers.map((transfer) {
        final from = detail.participants.firstWhere(
          (item) => item.id == transfer.fromParticipantId,
        );
        final to = detail.participants.firstWhere(
          (item) => item.id == transfer.toParticipantId,
        );
        return [
          from.displayName,
          to.displayName,
          transfer.amountCents,
          transfer.status,
        ];
      }),
      [],
      [
        'Transfer ID',
        'Previous status',
        'New status',
        'Actor snapshot',
        'Changed at',
      ],
      ...detail.transfers.expand(
        (transfer) => transfer.statusHistory.map(
          (change) => [
            transfer.id,
            change.previousStatus,
            change.newStatus,
            change.actorSnapshot,
            change.changedAt.toIso8601String(),
          ],
        ),
      ),
    ];
    final csv = const ListToCsvConverter().convert(rows);
    await SharePlus.instance.share(
      ShareParams(
        text: csv,
        subject: '${detail.game.name ?? 'Poker game'} CSV',
      ),
    );
  }

  Future<void> _sharePdf(V2GameDetail detail) async {
    final document = pw.Document();
    document.addPage(
      pw.MultiPage(
        build: (_) => [
          pw.Header(level: 0, child: pw.Text(detail.game.name ?? 'Poker game')),
          pw.Text(
            '${detail.game.settlementMode} settlement · '
            'revision ${detail.game.latestRevisionId ?? 'preview'}',
          ),
          pw.SizedBox(height: 12),
          pw.TableHelper.fromTextArray(
            headers: const ['Player snapshot', 'Buy-ins', 'Cash-out', 'Net'],
            data: detail.participants.map((participant) {
              final totals = detail.totalsFor(participant.id);
              return [
                participant.displayName,
                Money.formatCents(totals.buyInsCents, symbol: '\$'),
                Money.formatCents(totals.cashOutCents, symbol: '\$'),
                Money.formatCents(totals.netCents, symbol: '\$'),
              ];
            }).toList(),
          ),
          if (detail.transfers.isNotEmpty) ...[
            pw.SizedBox(height: 16),
            pw.Header(level: 1, child: pw.Text('Settlement transfers')),
            ...detail.transfers.map((transfer) {
              final from = detail.participants.firstWhere(
                (item) => item.id == transfer.fromParticipantId,
              );
              final to = detail.participants.firstWhere(
                (item) => item.id == transfer.toParticipantId,
              );
              return pw.Text(
                '${from.displayName} pays ${to.displayName} '
                '${Money.formatCents(transfer.amountCents, symbol: '\$')} '
                '(${transfer.status})',
              );
            }),
          ],
          if (detail.revisions.isNotEmpty) ...[
            pw.SizedBox(height: 16),
            pw.Header(level: 1, child: pw.Text('Revision history')),
            ...detail.revisions.map(
              (revision) => pw.Text(
                'Revision ${revision.revisionNumber}, through event '
                '${revision.throughEventSequence}'
                '${revision.reason == null ? '' : ': ${revision.reason}'}',
              ),
            ),
          ],
        ],
      ),
    );
    await Printing.sharePdf(
      bytes: await document.save(),
      filename: 'poker-ledger-game-${detail.game.id}.pdf',
    );
  }

  Future<void> _correctFinalized(V2GameDetail detail) async {
    final request = await showDialog<_CorrectionRequest>(
      context: context,
      builder: (_) => _CorrectionDialog(detail: detail),
    );
    if (request == null) return;
    await _run(
      () => ref
          .read(v2GameRepositoryProvider)
          .correctFinalizedGame(
            sessionId: detail.game.id,
            reason: request.reason,
            corrections: request.corrections,
          ),
    );
  }

  Future<void> _cancelGame(V2GameDetail detail) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Cancel this game?'),
        content: const Text(
          'This cancels the game for everyone. This cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Keep game'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Cancel game'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await _run(
      () => ref
          .read(v2GameRepositoryProvider)
          .cancelGame(detail.game.id, _kSilentHostReason),
    );
  }

  Future<void> _leaveGame(V2GameDetail detail) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Leave this game?'),
        content: const Text('You will be removed.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Stay'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Leave'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    final ok = await _run(
      () => ref.read(v2GameRepositoryProvider).leaveGame(detail.game.id),
    );
    if (!ok || !mounted) return;
    ref.read(sessionsListProvider.notifier).refresh();
    Navigator.of(context).pop();
  }

  Future<void> _removeParticipant(
    V2GameDetail detail,
    V2Participant participant,
  ) async {
    if (participant.profileId != null &&
        participant.profileId == detail.game.currentHostId) {
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Remove player?'),
        content: Text(
          'Remove ${participant.displayName} and delete all of their data '
          'from this game?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await _run(
      () => ref
          .read(v2GameRepositoryProvider)
          .removeParticipant(
            sessionId: detail.game.id,
            participantId: participant.id,
          ),
    );
  }
}

enum _AppBarMenuAction { refresh, inviteByHandle, cancelGame, leaveGame }

bool _canKickParticipant(V2GameDetail detail, V2Participant participant) {
  if (detail.game.isFinalized || detail.game.phase == 'cancelled') {
    return false;
  }
  if (participant.profileId != null &&
      participant.profileId == detail.game.currentHostId) {
    return false;
  }
  return true;
}

class _GameProgress extends StatelessWidget {
  final int currentStep;
  final int highestReached;
  final V2Game game;
  final bool summaryUnlocked;
  final ValueChanged<int> onStepPressed;

  const _GameProgress({
    required this.currentStep,
    required this.highestReached,
    required this.game,
    required this.summaryUnlocked,
    required this.onStepPressed,
  });

  bool _canOpen(int index) {
    if (game.isDraft) return index == 0;
    if (index == 0) return true;
    if (index == 1) return game.isLive || game.isSettling || game.isFinalized;
    return summaryUnlocked;
  }

  @override
  Widget build(BuildContext context) {
    const labels = ['Lobby', 'Live', 'Summary'];
    return Semantics(
      label: 'Game progress: ${labels[currentStep]}',
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
        child: Row(
          children: List.generate(labels.length, (index) {
            final active = index == currentStep;
            final complete = index <= highestReached && !active;
            final canOpen = _canOpen(index);
            return Expanded(
              child: InkWell(
                onTap: canOpen ? () => onStepPressed(index) : null,
                borderRadius: BorderRadius.circular(12),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        complete
                            ? Icons.check_circle
                            : active
                            ? Icons.radio_button_checked
                            : Icons.radio_button_unchecked,
                        size: 20,
                        color: active || complete
                            ? Theme.of(context).colorScheme.primary
                            : Theme.of(context).colorScheme.outline,
                      ),
                      const SizedBox(height: 4),
                      Text(
                        labels[index],
                        style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          fontWeight: active
                              ? FontWeight.bold
                              : FontWeight.normal,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            );
          }),
        ),
      ),
    );
  }
}

typedef _BuyInSaved =
    Future<bool> Function(V2Participant participant, int amountCents);

class _LobbyPage extends StatefulWidget {
  final V2GameDetail detail;
  final bool isHost;
  final String currentUserId;
  final bool showStartBar;
  final Future<void> Function() onRefresh;
  final VoidCallback onInviteByHandle;
  final ValueChanged<V2Participant> onSetBackup;
  final _BuyInSaved? onBuyInSaved;
  final VoidCallback? onStartGame;
  final VoidCallback? onLeave;
  final ValueChanged<V2Participant>? onRemoveParticipant;

  const _LobbyPage({
    required this.detail,
    required this.isHost,
    required this.currentUserId,
    required this.showStartBar,
    required this.onRefresh,
    required this.onInviteByHandle,
    required this.onSetBackup,
    required this.onBuyInSaved,
    required this.onStartGame,
    required this.onLeave,
    required this.onRemoveParticipant,
  });

  @override
  State<_LobbyPage> createState() => _LobbyPageState();
}

class _LobbyPageState extends State<_LobbyPage> {
  final Map<int, TextEditingController> _buyInControllers = {};
  final Map<int, Timer> _buyInDebouncers = {};
  final Map<int, int?> _lastSavedBuyInCents = {};

  @override
  void initState() {
    super.initState();
    _syncBuyInControllers(widget.detail);
  }

  @override
  void didUpdateWidget(covariant _LobbyPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncBuyInControllers(widget.detail);
  }

  @override
  void dispose() {
    for (final timer in _buyInDebouncers.values) {
      timer.cancel();
    }
    for (final controller in _buyInControllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  int _displayBuyInCents(V2Participant participant) {
    return participant.chosenBuyInCents ??
        widget.detail.game.defaultBuyInCents;
  }

  void _syncBuyInControllers(V2GameDetail detail) {
    final ids = detail.participants.map((p) => p.id).toSet();
    for (final id in _buyInControllers.keys.toList()) {
      if (!ids.contains(id)) {
        _buyInDebouncers.remove(id)?.cancel();
        _buyInControllers.remove(id)?.dispose();
        _lastSavedBuyInCents.remove(id);
      }
    }
    for (final participant in detail.participants) {
      final cents = _displayBuyInCents(participant);
      final controller = _buyInControllers.putIfAbsent(
        participant.id,
        () => TextEditingController(
          text: cents <= 0 ? '' : (cents / 100).toStringAsFixed(2),
        ),
      );
      final previousSaved = _lastSavedBuyInCents[participant.id];
      final serverCents = participant.chosenBuyInCents;
      if (serverCents != previousSaved) {
        final parsed = Money.tryParseCents(controller.text);
        final dirty =
            parsed != previousSaved &&
            !(controller.text.trim().isEmpty && previousSaved == null);
        if (!dirty) {
          final nextText = cents <= 0
              ? ''
              : (cents / 100).toStringAsFixed(2);
          if (controller.text != nextText) {
            controller.text = nextText;
          }
        }
        _lastSavedBuyInCents[participant.id] = serverCents;
      }
    }
  }

  void _scheduleBuyInSave(V2Participant participant, String raw) {
    final onSave = widget.onBuyInSaved;
    if (onSave == null) return;
    _buyInDebouncers[participant.id]?.cancel();
    _buyInDebouncers[participant.id] = Timer(
      const Duration(milliseconds: 400),
      () async {
        final text = raw.trim();
        if (text.isEmpty) return;
        final cents = Money.tryParseCents(text);
        if (cents == null || cents <= 0) return;
        if (_lastSavedBuyInCents[participant.id] == cents) return;
        final saved = await onSave(participant, cents);
        if (mounted && saved) {
          _lastSavedBuyInCents[participant.id] = cents;
        }
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final detail = widget.detail;
    final isHost = widget.isHost;
    final showStartBar = widget.showStartBar;
    final onLeave = widget.onLeave;
    final onRemoveParticipant = widget.onRemoveParticipant;
    final sentInvitations = detail.invitations.where(
      (invitation) => invitation.status == 'pending_invitee',
    );
    final awaitingBuyIn = detail.invitations.where(
      (invitation) => invitation.awaitingBuyIn,
    );
    final remaining = (2 - detail.participants.length).clamp(0, 2);
    final showLeaveBar = onLeave != null && !isHost;
    final bottomBarHeight = (showStartBar && isHost) || showLeaveBar
        ? 88.0
        : 0.0;
    final theme = Theme.of(context);
    final canEditBuyIns = widget.onBuyInSaved != null && detail.game.isDraft;

    return Stack(
      children: [
        RefreshIndicator(
          onRefresh: widget.onRefresh,
          child: ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: EdgeInsets.fromLTRB(16, 16, 16, 16 + bottomBarHeight),
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      'Accepted players (${detail.participants.length})',
                      style: theme.textTheme.titleMedium,
                    ),
                  ),
                  if (isHost && showStartBar)
                    IconButton(
                      tooltip: 'Invite by handle',
                      onPressed: widget.onInviteByHandle,
                      icon: const Icon(Icons.person_search),
                    ),
                ],
              ),
              const SizedBox(height: 8),
              ...detail.participants.map((participant) {
                final canEditThis =
                    canEditBuyIns &&
                    (isHost || participant.profileId == widget.currentUserId);
                final controller = _buyInControllers[participant.id]!;
                final buyInCents = _displayBuyInCents(participant);
                return Card(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        const CircleAvatar(child: Icon(Icons.person)),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                participant.displayName,
                                style: theme.textTheme.titleSmall,
                              ),
                              Text(
                                participant.profileId ==
                                        detail.game.backupHostId
                                    ? 'Accepted · Backup host'
                                    : 'Accepted',
                              ),
                              if (!detail.game.isDraft)
                                Text(
                                  'Buy-in ${Money.formatCents(buyInCents, symbol: '\$')}',
                                  style: theme.textTheme.bodySmall,
                                ),
                            ],
                          ),
                        ),
                        if (isHost &&
                            showStartBar &&
                            participant.profileId != null &&
                            participant.profileId !=
                                detail.game.currentHostId)
                          IconButton(
                            tooltip: 'Assign backup host',
                            onPressed: () => widget.onSetBackup(participant),
                            icon: Icon(
                              participant.profileId ==
                                      detail.game.backupHostId
                                  ? Icons.verified_user
                                  : Icons.person_add_alt_1,
                            ),
                          ),
                        if (onRemoveParticipant != null &&
                            _canKickParticipant(detail, participant))
                          IconButton(
                            tooltip: 'Remove player',
                            onPressed: () => onRemoveParticipant(participant),
                            icon: const Icon(Icons.person_remove_outlined),
                          ),
                        if (detail.game.isDraft) ...[
                          const SizedBox(width: 8),
                          SizedBox(
                            width: 120,
                            child: TextField(
                              controller: controller,
                              readOnly: !canEditThis,
                              decoration: const InputDecoration(
                                labelText: 'Buy-in',
                                isDense: true,
                                border: OutlineInputBorder(),
                              ),
                              keyboardType:
                                  const TextInputType.numberWithOptions(
                                decimal: true,
                              ),
                              onChanged: canEditThis
                                  ? (raw) =>
                                        _scheduleBuyInSave(participant, raw)
                                  : null,
                              inputFormatters: [
                                FilteringTextInputFormatter.allow(
                                  RegExp(r'^\d+(\.\d{0,2})?$'),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                );
              }),
              if (awaitingBuyIn.isNotEmpty) ...[
                const SizedBox(height: 16),
                Text(
                  'Waiting for buy-in (${awaitingBuyIn.length})',
                  style: theme.textTheme.titleMedium,
                ),
                ...awaitingBuyIn.map(
                  (invitation) => ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.payments_outlined),
                    title: Text(invitation.displayName),
                    subtitle: Text(
                      invitation.handle == null
                          ? 'Approved · choosing buy-in'
                          : '@${invitation.handle} · choosing buy-in',
                    ),
                  ),
                ),
              ],
              if (sentInvitations.isNotEmpty) ...[
                const SizedBox(height: 16),
                Text(
                  'Waiting for a response',
                  style: theme.textTheme.titleMedium,
                ),
                ...sentInvitations.map(
                  (invitation) => ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.schedule_send),
                    title: Text(invitation.displayName),
                    subtitle: Text(
                      invitation.handle == null
                          ? 'Invitation pending'
                          : '@${invitation.handle}',
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
        if (showStartBar && isHost)
          _StickyActionBar(
            child: FilledButton(
              onPressed: widget.onStartGame,
              child: Text(
                widget.onStartGame == null
                    ? 'Add $remaining more player'
                          '${remaining == 1 ? '' : 's'}'
                    : 'Move to live',
              ),
            ),
          )
        else if (showLeaveBar)
          _StickyActionBar(
            child: OutlinedButton(
              onPressed: onLeave,
              child: const Text('Leave game'),
            ),
          ),
      ],
    );
  }
}

class _LivePage extends StatelessWidget {
  final V2GameDetail detail;
  final bool isHost;
  final Future<void> Function() onRefresh;
  final ValueChanged<V2Participant> onRebuy;
  final ValueChanged<V2LedgerEvent> onDeleteEvent;
  final VoidCallback onInvite;
  final VoidCallback onReview;
  final ValueChanged<V2Participant>? onRemoveParticipant;
  final ValueChanged<V2Participant>? onToggleOut;

  const _LivePage({
    required this.detail,
    required this.isHost,
    required this.onRefresh,
    required this.onRebuy,
    required this.onDeleteEvent,
    required this.onInvite,
    required this.onReview,
    required this.onRemoveParticipant,
    required this.onToggleOut,
  });

  @override
  Widget build(BuildContext context) {
    final showEndBar = detail.game.isLive || !isHost;
    final bottomBarHeight = showEndBar ? 88.0 : 0.0;
    final canRecordRebuys = isHost && detail.game.isLive;
    final theme = Theme.of(context);
    return Stack(
      children: [
        RefreshIndicator(
          onRefresh: onRefresh,
          child: ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: EdgeInsets.fromLTRB(16, 16, 16, 16 + bottomBarHeight),
            children: [
              if (canRecordRebuys) ...[
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    onPressed: onInvite,
                    icon: const Icon(Icons.share),
                    label: const Text('Invite'),
                  ),
                ),
                const SizedBox(height: 8),
              ],
              ...detail.participants.map((participant) {
                final totals = detail.totalsFor(participant.id);
                final activeCashOut = detail.events.any(
                  (event) =>
                      event.participantId == participant.id &&
                      event.type == 'cash_out' &&
                      !detail.events.any(
                        (other) => other.reversesEventId == event.id,
                      ),
                );
                final canKick =
                    onRemoveParticipant != null &&
                    _canKickParticipant(detail, participant);
                final showHostActions =
                    canRecordRebuys || onToggleOut != null || canKick;
                return Card(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Expanded(
                                    child: Text(
                                      participant.displayName,
                                      style: theme.textTheme.titleSmall,
                                    ),
                                  ),
                                  if (participant.isOut)
                                    Padding(
                                      padding: const EdgeInsets.only(left: 6),
                                      child: Chip(
                                        visualDensity: VisualDensity.compact,
                                        materialTapTargetSize:
                                            MaterialTapTargetSize.shrinkWrap,
                                        label: const Text('Out'),
                                        avatar: Icon(
                                          Icons.block,
                                          size: 14,
                                          color: theme.colorScheme.error,
                                        ),
                                        labelStyle: theme.textTheme.labelSmall
                                            ?.copyWith(
                                              color: theme.colorScheme.error,
                                            ),
                                        side: BorderSide(
                                          color: theme.colorScheme.error
                                              .withValues(alpha: 0.4),
                                        ),
                                        padding: EdgeInsets.zero,
                                      ),
                                    )
                                  else if (activeCashOut)
                                    const Padding(
                                      padding: EdgeInsets.only(left: 6),
                                      child: Chip(
                                        visualDensity: VisualDensity.compact,
                                        materialTapTargetSize:
                                            MaterialTapTargetSize.shrinkWrap,
                                        avatar: Icon(Icons.check, size: 14),
                                        label: Text('Cashed out'),
                                        padding: EdgeInsets.zero,
                                      ),
                                    ),
                                ],
                              ),
                              const SizedBox(height: 2),
                              Text(
                                'Buy-ins ${Money.formatCents(totals.buyInsCents, symbol: '\$')}'
                                '${activeCashOut ? '  •  Cash-out ${Money.formatCents(totals.cashOutCents, symbol: '\$')}' : ''}',
                                style: theme.textTheme.bodySmall,
                              ),
                            ],
                          ),
                        ),
                        if (showHostActions) ...[
                          const SizedBox(width: 4),
                          if (canRecordRebuys)
                            TextButton(
                              onPressed:
                                  activeCashOut || participant.isOut
                                  ? null
                                  : () => onRebuy(participant),
                              child: const Text('Rebuy'),
                            ),
                          if (onToggleOut != null)
                            TextButton(
                              onPressed: () => onToggleOut!(participant),
                              child: Text(participant.isOut ? 'Undo out' : 'Out'),
                            ),
                          if (canKick)
                            IconButton(
                              tooltip: 'Remove player',
                              visualDensity: VisualDensity.compact,
                              onPressed: () =>
                                  onRemoveParticipant!(participant),
                              icon: const Icon(Icons.person_remove_outlined),
                            ),
                        ],
                      ],
                    ),
                  ),
                );
              }),
              if (isHost && detail.events.isNotEmpty)
                ExpansionTile(
                  title: const Text('Ledger history'),
                  subtitle: Text(
                    detail.game.isFinalized
                        ? 'Finalized history is locked.'
                        : 'Remove mistaken rebuys or cash-outs before finalizing.',
                  ),
                  children: detail.events.reversed.map((event) {
                    final participant = detail.participants.firstWhere(
                      (item) => item.id == event.participantId,
                    );
                    final canDelete =
                        !detail.game.isFinalized &&
                        (event.type == 'rebuy' || event.type == 'cash_out') &&
                        (detail.game.isLive || detail.game.isSettling);
                    return ListTile(
                      title: Text(
                        '${participant.displayName} • ${_eventLabel(event.type)}',
                      ),
                      subtitle: Text(
                        '${event.actorSnapshot ?? 'System'} · '
                        '${event.createdAt.toLocal()}'
                        '${event.reason == null ? '' : '\n${event.reason}'}',
                      ),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            Money.formatCents(event.amountCents, symbol: '\$'),
                          ),
                          if (canDelete)
                            IconButton(
                              tooltip: 'Remove',
                              onPressed: () => onDeleteEvent(event),
                              icon: const Icon(Icons.delete_outline),
                            ),
                        ],
                      ),
                    );
                  }).toList(),
                ),
            ],
          ),
        ),
        if (showEndBar)
          _StickyActionBar(
            child: FilledButton(
              onPressed: onReview,
              child: Text(
                isHost ? 'End game & enter cash-outs' : 'Review progress',
              ),
            ),
          ),
      ],
    );
  }
}

typedef _SettlementPreferencesChanged =
    Future<void> Function({
      required String settlementMode,
      required int? bankerParticipantId,
      required Set<int> paidUpfrontParticipantIds,
    });

typedef _CashOutSaved =
    Future<bool> Function(V2Participant participant, int amountCents);

class _SummaryPage extends StatefulWidget {
  final V2GameDetail detail;
  final bool isHost;
  final Future<void> Function() onRefresh;
  final _CashOutSaved? onCashOutSaved;
  final VoidCallback? onFinalize;
  final VoidCallback onShare;
  final VoidCallback onExport;
  final VoidCallback onPdf;
  final String currentUserId;
  final void Function(V2SettlementTransfer transfer, String status)
  onTransferStatus;
  final VoidCallback? onCorrect;
  final ValueChanged<V2Participant>? onRemoveParticipant;
  final _SettlementPreferencesChanged? onSettlementPreferencesChanged;

  const _SummaryPage({
    required this.detail,
    required this.isHost,
    required this.onRefresh,
    required this.onCashOutSaved,
    required this.onFinalize,
    required this.onShare,
    required this.onExport,
    required this.onPdf,
    required this.currentUserId,
    required this.onTransferStatus,
    required this.onCorrect,
    required this.onRemoveParticipant,
    required this.onSettlementPreferencesChanged,
  });

  @override
  State<_SummaryPage> createState() => _SummaryPageState();
}

class _SummaryPageState extends State<_SummaryPage> {
  late String _settlementMode;
  int? _bankerParticipantId;
  late Set<int> _paidUpfrontParticipantIds;
  final Map<int, TextEditingController> _cashOutControllers = {};
  final Map<int, Timer> _cashOutDebouncers = {};
  final Map<int, int?> _lastSavedCashOutCents = {};

  @override
  void initState() {
    super.initState();
    _syncFromDetail(widget.detail);
    _syncCashOutControllers(widget.detail);
  }

  @override
  void didUpdateWidget(covariant _SummaryPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.detail.game.settlementMode !=
            widget.detail.game.settlementMode ||
        oldWidget.detail.game.bankerParticipantId !=
            widget.detail.game.bankerParticipantId ||
        !_samePaidUpfront(oldWidget.detail, widget.detail)) {
      _syncFromDetail(widget.detail);
    }
    _syncCashOutControllers(widget.detail);
  }

  @override
  void dispose() {
    for (final timer in _cashOutDebouncers.values) {
      timer.cancel();
    }
    for (final controller in _cashOutControllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  bool _samePaidUpfront(V2GameDetail a, V2GameDetail b) {
    final aIds = a.participants
        .where((p) => p.paidUpfront)
        .map((p) => p.id)
        .toSet();
    final bIds = b.participants
        .where((p) => p.paidUpfront)
        .map((p) => p.id)
        .toSet();
    return aIds.length == bIds.length && aIds.containsAll(bIds);
  }

  void _syncFromDetail(V2GameDetail detail) {
    _settlementMode = detail.game.settlementMode;
    _bankerParticipantId = detail.game.bankerParticipantId;
    _paidUpfrontParticipantIds = detail.participants
        .where((participant) => participant.paidUpfront)
        .map((participant) => participant.id)
        .toSet();
  }

  int? _activeCashOutCents(V2GameDetail detail, int participantId) {
    for (final event in detail.events) {
      if (event.participantId != participantId || event.type != 'cash_out') {
        continue;
      }
      final reversed = detail.events.any(
        (other) => other.reversesEventId == event.id,
      );
      if (!reversed) return event.amountCents.abs();
    }
    return null;
  }

  void _syncCashOutControllers(V2GameDetail detail) {
    final ids = detail.participants.map((p) => p.id).toSet();
    for (final id in _cashOutControllers.keys.toList()) {
      if (!ids.contains(id)) {
        _cashOutDebouncers.remove(id)?.cancel();
        _cashOutControllers.remove(id)?.dispose();
        _lastSavedCashOutCents.remove(id);
      }
    }
    for (final participant in detail.participants) {
      final cents = _activeCashOutCents(detail, participant.id) ??
          (participant.isOut ? 0 : null);
      final controller = _cashOutControllers.putIfAbsent(
        participant.id,
        () => TextEditingController(
          text: cents == null ? '' : (cents / 100).toStringAsFixed(2),
        ),
      );
      final previousSaved = _lastSavedCashOutCents[participant.id];
      if (cents != previousSaved) {
        final parsed = Money.tryParseCents(controller.text);
        final dirty =
            parsed != previousSaved &&
            !(controller.text.trim().isEmpty && previousSaved == null);
        if (!dirty) {
          final nextText = cents == null
              ? ''
              : (cents / 100).toStringAsFixed(2);
          if (controller.text != nextText) {
            controller.text = nextText;
          }
        }
        _lastSavedCashOutCents[participant.id] = cents;
      }
    }
  }

  void _formatCashOutField(TextEditingController controller) {
    final cents = Money.tryParseCents(controller.text);
    if (cents == null) return;
    final formatted = (cents / 100).toStringAsFixed(2);
    if (controller.text != formatted) {
      controller.value = TextEditingValue(
        text: formatted,
        selection: TextSelection.collapsed(offset: formatted.length),
      );
    }
  }

  void _scheduleCashOutSave(V2Participant participant, String raw) {
    final onSave = widget.onCashOutSaved;
    if (onSave == null) return;
    _cashOutDebouncers[participant.id]?.cancel();
    _cashOutDebouncers[participant.id] = Timer(
      const Duration(milliseconds: 400),
      () async {
        final text = raw.trim();
        if (text.isEmpty) return;
        final cents = Money.tryParseCents(text);
        if (cents == null || cents < 0) return;
        if (_lastSavedCashOutCents[participant.id] == cents) return;
        final saved = await onSave(participant, cents);
        if (mounted && saved) {
          _lastSavedCashOutCents[participant.id] = cents;
        }
      },
    );
  }

  Future<void> _persistPreferences({
    required String settlementMode,
    required int? bankerParticipantId,
    required Set<int> paidUpfrontParticipantIds,
  }) async {
    final callback = widget.onSettlementPreferencesChanged;
    if (callback == null) return;
    if (settlementMode == 'banker' && bankerParticipantId == null) return;
    await callback(
      settlementMode: settlementMode,
      bankerParticipantId: bankerParticipantId,
      paidUpfrontParticipantIds: settlementMode == 'banker'
          ? paidUpfrontParticipantIds
          : const {},
    );
  }

  @override
  Widget build(BuildContext context) {
    final detail = widget.detail;
    final isHost = widget.isHost;
    final canEditCashOuts = widget.onCashOutSaved != null;
    final onFinalize = widget.onFinalize;
    final onShare = widget.onShare;
    final onExport = widget.onExport;
    final onPdf = widget.onPdf;
    final currentUserId = widget.currentUserId;
    final onTransferStatus = widget.onTransferStatus;
    final onCorrect = widget.onCorrect;
    final canEditMode = widget.onSettlementPreferencesChanged != null;
    final showFinalizeBar = !detail.game.isFinalized && isHost;
    final bottomBarHeight = showFinalizeBar ? 88.0 : 0.0;

    final missingCashOuts = detail.participants
        .where(
          (participant) => !detail.events.any(
            (event) =>
                event.participantId == participant.id &&
                event.type == 'cash_out' &&
                !detail.events.any(
                  (other) => other.reversesEventId == event.id,
                ),
          ),
        )
        .toList();
    final proposedTransfers =
        missingCashOuts.isEmpty && detail.ledgerBalanceCents == 0
        ? _previewTransfers(
            detail,
            settlementMode: _settlementMode,
            bankerParticipantId: _bankerParticipantId,
            paidUpfrontParticipantIds: _paidUpfrontParticipantIds,
          )
        : const <SettlementTransfer>[];
    return Stack(
      children: [
        RefreshIndicator(
          onRefresh: widget.onRefresh,
          child: ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: EdgeInsets.fromLTRB(16, 16, 16, 16 + bottomBarHeight),
            children: [
              if (canEditMode) ...[
                Text(
                  'Settlement mode',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 8),
                SegmentedButton<String>(
                  segments: const [
                    ButtonSegment(value: 'pairwise', label: Text('Pairwise')),
                    ButtonSegment(value: 'banker', label: Text('Banker')),
                  ],
                  selected: {_settlementMode},
                  onSelectionChanged: (selection) {
                    final mode = selection.first;
                    setState(() {
                      _settlementMode = mode;
                      if (mode == 'pairwise') {
                        _bankerParticipantId = null;
                        _paidUpfrontParticipantIds.clear();
                      }
                    });
                    _persistPreferences(
                      settlementMode: mode,
                      bankerParticipantId: mode == 'banker'
                          ? _bankerParticipantId
                          : null,
                      paidUpfrontParticipantIds: _paidUpfrontParticipantIds,
                    );
                  },
                ),
                if (_settlementMode == 'banker') ...[
                  const SizedBox(height: 12),
                  DropdownButtonFormField<int>(
                    key: ValueKey('banker-$_bankerParticipantId'),
                    initialValue: _bankerParticipantId,
                    decoration: const InputDecoration(
                      labelText: 'Banker',
                      border: OutlineInputBorder(),
                    ),
                    items: detail.participants
                        .map(
                          (participant) => DropdownMenuItem(
                            value: participant.id,
                            child: Text(participant.displayName),
                          ),
                        )
                        .toList(),
                    onChanged: (id) {
                      setState(() {
                        _bankerParticipantId = id;
                        if (id != null) {
                          _paidUpfrontParticipantIds.remove(id);
                        }
                      });
                      _persistPreferences(
                        settlementMode: 'banker',
                        bankerParticipantId: id,
                        paidUpfrontParticipantIds: _paidUpfrontParticipantIds,
                      );
                    },
                  ),
                  if (_bankerParticipantId != null) ...[
                    const SizedBox(height: 16),
                    Text(
                      'Already paid the banker',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const Text(
                      'Mark payments already completed outside this settlement.',
                    ),
                    ...detail.participants
                        .where(
                          (participant) =>
                              participant.id != _bankerParticipantId,
                        )
                        .map(
                          (participant) => CheckboxListTile(
                            contentPadding: EdgeInsets.zero,
                            value: _paidUpfrontParticipantIds.contains(
                              participant.id,
                            ),
                            onChanged: (value) {
                              setState(() {
                                if (value ?? false) {
                                  _paidUpfrontParticipantIds.add(
                                    participant.id,
                                  );
                                } else {
                                  _paidUpfrontParticipantIds.remove(
                                    participant.id,
                                  );
                                }
                              });
                              _persistPreferences(
                                settlementMode: 'banker',
                                bankerParticipantId: _bankerParticipantId,
                                paidUpfrontParticipantIds:
                                    _paidUpfrontParticipantIds,
                              );
                            },
                            title: Text(participant.displayName),
                          ),
                        ),
                  ],
                ],
                const SizedBox(height: 16),
              ] else if (!detail.game.isFinalized) ...[
                Text(
                  'Settlement: ${_settlementMode == 'banker' ? 'Banker' : 'Pairwise'}',
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
                const SizedBox(height: 16),
              ],
              ...detail.participants.map((participant) {
                final totals = detail.totalsFor(participant.id);
                final needsCashOut = missingCashOuts.contains(participant);
                final controller = _cashOutControllers[participant.id]!;
                final onRemoveParticipant = widget.onRemoveParticipant;
                return Card(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Expanded(
                                    child: Text(
                                      participant.displayName,
                                      style: Theme.of(
                                        context,
                                      ).textTheme.titleMedium,
                                    ),
                                  ),
                                  if (participant.isOut)
                                    Chip(
                                      visualDensity: VisualDensity.compact,
                                      materialTapTargetSize:
                                          MaterialTapTargetSize.shrinkWrap,
                                      label: const Text('Out'),
                                      avatar: Icon(
                                        Icons.block,
                                        size: 14,
                                        color: Theme.of(
                                          context,
                                        ).colorScheme.error,
                                      ),
                                      padding: EdgeInsets.zero,
                                    ),
                                ],
                              ),
                              const SizedBox(height: 4),
                              Text(
                                'Buy-ins ${Money.formatCents(totals.buyInsCents, symbol: '\$')} • '
                                'Cash-out ${needsCashOut ? 'not entered' : Money.formatCents(totals.cashOutCents, symbol: '\$')}',
                              ),
                              if (!needsCashOut) ...[
                                const SizedBox(height: 2),
                                Text(
                                  'Net ${Money.formatCents(totals.netCents, symbol: '\$')}',
                                  style: TextStyle(
                                    fontWeight: FontWeight.w600,
                                    color: totals.netCents > 0
                                        ? Colors.green
                                        : totals.netCents < 0
                                        ? Theme.of(context).colorScheme.error
                                        : null,
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                        if (onRemoveParticipant != null &&
                            _canKickParticipant(detail, participant))
                          IconButton(
                            tooltip: 'Remove player',
                            onPressed: () => onRemoveParticipant(participant),
                            icon: const Icon(Icons.person_remove_outlined),
                          ),
                        const SizedBox(width: 12),
                        SizedBox(
                          width: 128,
                          child: TextField(
                            controller: controller,
                            readOnly: !canEditCashOuts,
                            decoration: const InputDecoration(
                              labelText: 'Cash out',
                              isDense: true,
                              border: OutlineInputBorder(),
                            ),
                            keyboardType:
                                const TextInputType.numberWithOptions(
                              decimal: true,
                            ),
                            onChanged: canEditCashOuts
                                ? (raw) =>
                                      _scheduleCashOutSave(participant, raw)
                                : null,
                            onEditingComplete: () {
                              _formatCashOutField(controller);
                              FocusScope.of(context).unfocus();
                            },
                            onTapOutside: (_) =>
                                _formatCashOutField(controller),
                            inputFormatters: [
                              FilteringTextInputFormatter.allow(
                                RegExp(r'^\d+(\.\d{0,2})?$'),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              }),
              const Divider(),
              if (!detail.game.isFinalized) ...[
                _RequirementTile(
                  complete: missingCashOuts.isEmpty,
                  title: missingCashOuts.isEmpty
                      ? 'Every player has a cash-out'
                      : 'Enter ${missingCashOuts.length} remaining cash-out${missingCashOuts.length == 1 ? '' : 's'}',
                ),
                _RequirementTile(
                  complete: detail.ledgerBalanceCents == 0,
                  title: detail.ledgerBalanceCents == 0
                      ? 'Buy-ins and cash-outs balance'
                      : 'Ledger is off by ${Money.formatCents(detail.ledgerBalanceCents.abs(), symbol: '\$')}',
                ),
              ],
              if (detail.revisions.isNotEmpty)
                ExpansionTile(
                  tilePadding: EdgeInsets.zero,
                  title: const Text('Revision history'),
                  subtitle: Text(
                    '${detail.revisions.length} locked '
                    'revision${detail.revisions.length == 1 ? '' : 's'}',
                  ),
                  children: detail.revisions.reversed
                      .map(
                        (revision) => ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: Icon(
                            revision.supersededAt == null
                                ? Icons.verified_outlined
                                : Icons.history,
                          ),
                          title: Text(
                            'Revision ${revision.revisionNumber} · '
                            'through event ${revision.throughEventSequence}',
                          ),
                          subtitle: Text(
                            '${revision.settlementMode} · '
                            '${revision.createdAt.toLocal()}'
                            '${revision.reason == null ? '' : '\n${revision.reason}'}',
                          ),
                        ),
                      )
                      .toList(),
                ),
              if (!detail.game.isFinalized && proposedTransfers.isNotEmpty) ...[
                const Divider(),
                Text(
                  'Proposed transfers',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                ...proposedTransfers.map((transfer) {
                  final from = detail.participants.firstWhere(
                    (item) => item.id == transfer.fromParticipantId,
                  );
                  final to = detail.participants.firstWhere(
                    (item) => item.id == transfer.toParticipantId,
                  );
                  return ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text('${from.displayName} pays ${to.displayName}'),
                    trailing: Text(
                      Money.formatCents(transfer.amountCents, symbol: '\$'),
                    ),
                  );
                }),
              ],
              if (detail.transfers.isNotEmpty) ...[
                const SizedBox(height: 12),
                Text(
                  'Settlement',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                ...detail.transfers.map((transfer) {
                  final from = detail.participants.firstWhere(
                    (item) => item.id == transfer.fromParticipantId,
                  );
                  final to = detail.participants.firstWhere(
                    (item) => item.id == transfer.toParticipantId,
                  );
                  final isPayer = from.profileId == currentUserId;
                  final isRecipient = to.profileId == currentUserId;
                  return Card(
                    child: Column(
                      children: [
                        ListTile(
                          leading: const Icon(Icons.payments_outlined),
                          title: Text(
                            '${from.displayName} pays ${to.displayName}',
                          ),
                          subtitle: Text('Status: ${transfer.status}'),
                          trailing: Text(
                            Money.formatCents(
                              transfer.amountCents,
                              symbol: '\$',
                            ),
                          ),
                        ),
                        if (transfer.statusHistory.isNotEmpty)
                          ExpansionTile(
                            title: const Text('Status history'),
                            children: transfer.statusHistory
                                .map(
                                  (change) => ListTile(
                                    dense: true,
                                    title: Text(
                                      '${change.previousStatus} → '
                                      '${change.newStatus}',
                                    ),
                                    subtitle: Text(
                                      '${change.actorSnapshot} · '
                                      '${change.changedAt.toLocal()}',
                                    ),
                                  ),
                                )
                                .toList(),
                          ),
                        if (detail.game.isFinalized &&
                            transfer.status != 'received' &&
                            (isPayer || isRecipient))
                          Padding(
                            padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                            child: Wrap(
                              alignment: WrapAlignment.end,
                              spacing: 8,
                              children: [
                                if ((isPayer || isRecipient) &&
                                    (transfer.status == 'pending' ||
                                        transfer.status == 'disputed'))
                                  TextButton(
                                    onPressed: () =>
                                        onTransferStatus(transfer, 'paid'),
                                    child: const Text('Mark paid'),
                                  ),
                                if (isRecipient && transfer.status == 'paid')
                                  FilledButton.tonal(
                                    onPressed: () => onTransferStatus(
                                      transfer,
                                      'received',
                                    ),
                                    child: const Text('Confirm received'),
                                  ),
                              ],
                            ),
                          ),
                      ],
                    ),
                  );
                }),
              ],
              const SizedBox(height: 20),
              if (detail.game.isFinalized) ...[
                FilledButton.tonalIcon(
                  onPressed: onShare,
                  icon: const Icon(Icons.share),
                  label: const Text('Share summary'),
                ),
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  onPressed: onExport,
                  icon: const Icon(Icons.download_outlined),
                  label: const Text('Export audit CSV'),
                ),
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  onPressed: onPdf,
                  icon: const Icon(Icons.picture_as_pdf_outlined),
                  label: const Text('Export PDF'),
                ),
                if (onCorrect != null) ...[
                  const SizedBox(height: 8),
                  TextButton.icon(
                    onPressed: onCorrect,
                    icon: const Icon(Icons.history),
                    label: const Text('Correct finalized game'),
                  ),
                ],
              ],
            ],
          ),
        ),
        if (showFinalizeBar)
          _StickyActionBar(
            child: FilledButton(
              onPressed: onFinalize,
              child: Text(
                onFinalize != null
                    ? 'Finalize game'
                    : 'Complete the items above',
              ),
            ),
          ),
      ],
    );
  }
}

class _StickyActionBar extends StatelessWidget {
  final Widget child;

  const _StickyActionBar({required this.child});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Align(
      alignment: Alignment.bottomCenter,
      child: Material(
        elevation: 8,
        color: theme.colorScheme.surface,
        child: SafeArea(
          top: false,
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
            decoration: BoxDecoration(
              border: Border(top: BorderSide(color: theme.dividerColor)),
            ),
            child: child,
          ),
        ),
      ),
    );
  }
}

class _CorrectionRequest {
  final String reason;
  final List<Map<String, Object?>> corrections;

  const _CorrectionRequest({required this.reason, required this.corrections});
}

class _CorrectionDialog extends StatefulWidget {
  final V2GameDetail detail;

  const _CorrectionDialog({required this.detail});

  @override
  State<_CorrectionDialog> createState() => _CorrectionDialogState();
}

class _CorrectionDialogState extends State<_CorrectionDialog> {
  final _reasonController = TextEditingController();
  final Set<int> _selectedEventIds = {};
  final Map<int, TextEditingController> _amountControllers = {};

  List<V2LedgerEvent> get _availableEvents => widget.detail.events
      .where(
        (event) =>
            const {
              'initial_buy_in',
              'rebuy',
              'cash_out',
            }.contains(event.type) &&
            !widget.detail.events.any(
              (candidate) => candidate.reversesEventId == event.id,
            ),
      )
      .toList();

  @override
  void initState() {
    super.initState();
    for (final event in _availableEvents) {
      _amountControllers[event.id] = TextEditingController(
        text: (event.amountCents.abs() / 100).toStringAsFixed(2),
      );
    }
  }

  @override
  void dispose() {
    _reasonController.dispose();
    for (final controller in _amountControllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  int? _replacementAmount(V2LedgerEvent event) {
    return Money.tryParseCents(_amountControllers[event.id]!.text);
  }

  int? get _projectedBalance {
    var balance = widget.detail.ledgerBalanceCents;
    for (final event in _availableEvents) {
      if (!_selectedEventIds.contains(event.id)) continue;
      final amount = _replacementAmount(event);
      if (amount == null || amount <= 0) return null;
      balance -= event.amountCents;
      balance += event.type == 'cash_out' ? -amount : amount;
    }
    return balance;
  }

  void _submit() {
    final reason = _reasonController.text.trim();
    if (reason.isEmpty || _selectedEventIds.isEmpty || _projectedBalance != 0) {
      return;
    }
    final corrections = _availableEvents
        .where((event) => _selectedEventIds.contains(event.id))
        .map(
          (event) => <String, Object?>{
            'reverses_event_id': event.id,
            'replacement_type': event.type,
            'replacement_amount_cents': _replacementAmount(event)!,
          },
        )
        .toList();
    Navigator.pop(
      context,
      _CorrectionRequest(reason: reason, corrections: corrections),
    );
  }

  @override
  Widget build(BuildContext context) {
    final projected = _projectedBalance;
    final canSubmit =
        _reasonController.text.trim().isNotEmpty &&
        _selectedEventIds.isNotEmpty &&
        projected == 0;
    return AlertDialog(
      title: const Text('Correct finalized game'),
      content: SizedBox(
        width: 560,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Select every incorrect entry and enter its replacement. '
                'The preview must remain exactly balanced.',
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _reasonController,
                onChanged: (_) => setState(() {}),
                decoration: const InputDecoration(
                  labelText: 'Correction reason',
                ),
              ),
              const SizedBox(height: 12),
              ..._availableEvents.map((event) {
                final participant = widget.detail.participants.firstWhere(
                  (item) => item.id == event.participantId,
                );
                final selected = _selectedEventIds.contains(event.id);
                return Card(
                  child: Column(
                    children: [
                      CheckboxListTile(
                        value: selected,
                        onChanged: (value) => setState(() {
                          if (value == true) {
                            _selectedEventIds.add(event.id);
                          } else {
                            _selectedEventIds.remove(event.id);
                          }
                        }),
                        title: Text(
                          '${participant.displayName} · '
                          '${_eventLabel(event.type)}',
                        ),
                        subtitle: Text(
                          Money.formatCents(
                            event.amountCents.abs(),
                            symbol: '\$',
                          ),
                        ),
                      ),
                      if (selected)
                        Padding(
                          padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                          child: TextField(
                            controller: _amountControllers[event.id],
                            onChanged: (_) => setState(() {}),
                            keyboardType: const TextInputType.numberWithOptions(
                              decimal: true,
                            ),
                            decoration: const InputDecoration(
                              labelText: 'Replacement amount',
                              prefixText: '\$',
                            ),
                          ),
                        ),
                    ],
                  ),
                );
              }),
              const SizedBox(height: 12),
              _RequirementTile(
                complete: projected == 0 && _selectedEventIds.isNotEmpty,
                title: projected == null
                    ? 'Enter valid replacement amounts'
                    : projected == 0 && _selectedEventIds.isNotEmpty
                    ? 'Corrected ledger remains balanced'
                    : 'Preview is off by ${Money.formatCents(projected.abs(), symbol: '\$')}',
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: canSubmit ? _submit : null,
          child: const Text('Create correction revision'),
        ),
      ],
    );
  }
}

class _RequirementTile extends StatelessWidget {
  final bool complete;
  final String title;

  const _RequirementTile({required this.complete, required this.title});

  @override
  Widget build(BuildContext context) {
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(
        complete ? Icons.check_circle : Icons.radio_button_unchecked,
        color: complete
            ? Colors.green
            : Theme.of(context).colorScheme.onSurfaceVariant,
      ),
      title: Text(title),
    );
  }
}

class _ProfileSearchSheet extends StatefulWidget {
  final Future<List<DiscoverableProfile>> Function(String query) search;

  const _ProfileSearchSheet({required this.search});

  @override
  State<_ProfileSearchSheet> createState() => _ProfileSearchSheetState();
}

class _ProfileSearchSheetState extends State<_ProfileSearchSheet> {
  final _controller = TextEditingController();
  List<DiscoverableProfile> _results = [];
  bool _loading = false;
  String? _message;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    final query = _controller.text.trim();
    if (query.length < 2) {
      setState(() => _message = 'Enter at least two characters.');
      return;
    }
    setState(() {
      _loading = true;
      _message = null;
    });
    try {
      final results = await widget.search(query);
      if (!mounted) return;
      setState(() {
        _results = results;
        _message = _results.isEmpty
            ? 'No discoverable account matches that handle or display name.'
            : null;
      });
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          16,
          0,
          16,
          MediaQuery.viewInsetsOf(context).bottom + 16,
        ),
        child: SizedBox(
          height: MediaQuery.sizeOf(context).height * 0.7,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Invite a player',
                style: Theme.of(context).textTheme.headlineSmall,
              ),
              const SizedBox(height: 4),
              const Text(
                'Search only by unique handle or display name. Email addresses '
                'and registration status are never exposed.',
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _controller,
                autofocus: true,
                textInputAction: TextInputAction.search,
                onSubmitted: (_) => _search(),
                decoration: InputDecoration(
                  labelText: 'Handle or display name',
                  prefixText: '@',
                  suffixIcon: IconButton(
                    onPressed: _loading ? null : _search,
                    icon: const Icon(Icons.search),
                  ),
                ),
              ),
              if (_loading) const LinearProgressIndicator(),
              if (_message != null)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  child: Text(_message!),
                ),
              Expanded(
                child: ListView.builder(
                  itemCount: _results.length,
                  itemBuilder: (context, index) {
                    final profile = _results[index];
                    final state = switch (profile.resultState) {
                      'participating' => 'Already in game',
                      'invited' => 'Invitation pending',
                      'requested' => 'Join request pending',
                      _ => '@${profile.handle}',
                    };
                    return ListTile(
                      leading: const CircleAvatar(child: Icon(Icons.person)),
                      title: Text(profile.displayName),
                      subtitle: Text(
                        profile.canInvite
                            ? '@${profile.handle}'
                            : '@${profile.handle} · $state',
                      ),
                      trailing: profile.canInvite
                          ? const Icon(Icons.person_add_alt_1)
                          : const Icon(Icons.check_circle_outline),
                      onTap: profile.canInvite
                          ? () => Navigator.pop(context, profile)
                          : null,
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MoneyDialog extends StatefulWidget {
  final String title;

  const _MoneyDialog({required this.title});

  @override
  State<_MoneyDialog> createState() => _MoneyDialogState();
}

class _MoneyDialogState extends State<_MoneyDialog> {
  final _controller = TextEditingController(text: '20.00');
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: TextField(
        controller: _controller,
        autofocus: true,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        decoration: InputDecoration(
          labelText: 'Amount',
          prefixText: '\$',
          errorText: _error,
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () {
            final cents = Money.tryParseCents(_controller.text);
            if (cents == null || cents <= 0) {
              setState(() => _error = 'Enter an amount greater than zero.');
              return;
            }
            Navigator.pop(context, cents);
          },
          child: const Text('Save'),
        ),
      ],
    );
  }
}

class _ErrorState extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;

  const _ErrorState({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline, size: 48),
            const SizedBox(height: 12),
            Text(message, textAlign: TextAlign.center),
            const SizedBox(height: 12),
            FilledButton(onPressed: onRetry, child: const Text('Try again')),
          ],
        ),
      ),
    );
  }
}

List<SettlementTransfer> _previewTransfers(
  V2GameDetail detail, {
  String? settlementMode,
  int? bankerParticipantId,
  Set<int>? paidUpfrontParticipantIds,
}) {
  final mode = settlementMode ?? detail.game.settlementMode;
  final bankerId = bankerParticipantId ?? detail.game.bankerParticipantId;
  final paidIds =
      paidUpfrontParticipantIds ??
      detail.participants
          .where((participant) => participant.paidUpfront)
          .map((participant) => participant.id)
          .toSet();
  try {
    if (mode == 'banker' && bankerId != null) {
      return SettlementEngine.settleBanker(
        participants: detail.participants.map((participant) {
          final totals = detail.totalsFor(participant.id);
          return BankerSettlementParticipant(
            participantId: participant.id,
            buyInCents: totals.buyInsCents,
            cashOutCents: totals.cashOutCents,
            paidUpfront: paidIds.contains(participant.id),
          );
        }),
        bankerParticipantId: bankerId,
      ).transfers;
    }
    return SettlementEngine.settlePairwise(
      detail.participants.map((participant) {
        final totals = detail.totalsFor(participant.id);
        return SettlementBalance(
          participantId: participant.id,
          netCents: totals.netCents,
        );
      }),
    ).transfers;
  } on SettlementValidationException {
    return const [];
  }
}

String _eventLabel(String type) => switch (type) {
  'initial_buy_in' => 'Initial buy-in',
  'rebuy' => 'Rebuy',
  'cash_out' => 'Cash-out',
  'reversal' => 'Reversal',
  'correction' => 'Correction',
  _ => type,
};

String _friendlyError(Object error) {
  final message = error is PostgrestException
      ? (error.message)
      : error.toString();
  final text = message.toLowerCase();
  if (text.contains('compatible client') ||
      text.contains('upgrade') ||
      text.contains('update poker ledger to continue')) {
    return 'Update Poker Ledger before changing this game.';
  }
  if (text.contains('only the current host')) {
    return 'Only the current host can make this change.';
  }
  if (text.contains('permission') ||
      text.contains('row-level security') ||
      text.contains('42501')) {
    return 'You have read-only access to this game.';
  }
  if (text.contains('transactional ledger api') ||
      text.contains('transactional game api')) {
    return 'This game must be updated through Poker Ledger actions. Retry, '
        'or refresh and try again.';
  }
  if (text.contains('already has a cash-out')) {
    return 'That cash-out was already saved. Refresh and try again.';
  }
  if (text.contains('buy-in must be greater than zero')) {
    return 'Buy-in must be greater than zero.';
  }
  if (text.contains('buy-ins cannot be changed after the game is live') ||
      text.contains('only be set in the lobby')) {
    return 'Buy-ins can only be changed in the lobby before the game goes live.';
  }
  if (text.contains('cash-out cannot be negative')) {
    return 'Cash-out cannot be negative.';
  }
  if (text.contains('cash-out must be greater than zero') ||
      text.contains('ledger_events_amount_cents_check') ||
      (text.contains('amount_cents') && text.contains('check constraint'))) {
    return 'Enter a valid cash-out amount.';
  }
  if (text.contains('only be marked out while')) {
    return 'Players can only be marked out while the game is live or in summary.';
  }
  if (text.contains('reverses_event_id_key') ||
      text.contains('already reversed') ||
      text.contains('reversal must exactly offset')) {
    return 'That entry was already changed. Refresh and try again.';
  }
  if (text.contains('not valid in this game phase') ||
      text.contains('can only be set while settling') ||
      text.contains('only be removed before finalization')) {
    return 'This action isn’t available in the current game phase. Refresh '
        'and try again.';
  }
  if (text.contains('matching request is still processing')) {
    return 'Still saving a previous change. Wait a moment and retry.';
  }
  if (text.contains('idempotency key was already used')) {
    return 'Retry the action — the previous request conflicted.';
  }
  if (text.contains('at least two') || text.contains('accepted players')) {
    return 'Add at least two accepted players before starting the game.';
  }
  if (text.contains('only leave while the game is in the lobby') ||
      text.contains('only leave while')) {
    return 'You can only leave while the game is in the lobby.';
  }
  if (text.contains('host cannot leave')) {
    return 'The host cannot leave. Cancel the game instead.';
  }
  if (text.contains('host cannot be removed')) {
    return 'The host cannot be removed from the game.';
  }
  if (text.contains('cannot be removed after the game is finalized') ||
      text.contains('cannot be removed in this game phase')) {
    return 'Players can’t be removed in this game phase.';
  }
  if (text.contains('only a draft') || text.contains('draft game can start')) {
    return 'This game has already started.';
  }
  if (text.contains('choose a settlement') ||
      text.contains('choose an accepted player as banker')) {
    return 'Choose a valid settlement mode before starting.';
  }
  if (text.contains('balance') || text.contains('buy-ins and cash-outs')) {
    return 'Buy-ins and cash-outs must balance exactly before finalizing.';
  }
  if (text.contains('every player needs a cash-out') ||
      (text.contains('cash-out') && text.contains('required'))) {
    return 'Enter and save every cash-out before finalizing.';
  }
  if (text.contains('expired') || text.contains('join code')) {
    return 'This join code is invalid, expired, or revoked.';
  }
  if (text.contains('backup host') ||
      text.contains('choose another accepted participant')) {
    return 'Choose an accepted participant who is eligible to host this game.';
  }
  if (text.contains('network') ||
      text.contains('socket') ||
      text.contains('connection')) {
    return 'Check your connection and try again.';
  }
  return 'The change could not be saved. Refresh and try again.';
}
