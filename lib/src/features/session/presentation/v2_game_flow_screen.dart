import 'package:csv/csv.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import 'package:share_plus/share_plus.dart';

import '../../../utils/money.dart';
import '../data/v2_game_providers.dart';
import '../domain/v2_game_models.dart';
import '../domain/settlement_engine.dart';

class V2GameFlowScreen extends ConsumerStatefulWidget {
  final int sessionId;

  const V2GameFlowScreen({super.key, required this.sessionId});

  @override
  ConsumerState<V2GameFlowScreen> createState() => _V2GameFlowScreenState();
}

class _V2GameFlowScreenState extends ConsumerState<V2GameFlowScreen> {
  int _draftStep = 0;
  bool _showSummary = false;
  String? _settlementMode;
  int? _bankerParticipantId;
  final Set<int> _paidUpfrontParticipantIds = {};
  bool _busy = false;
  String? _operationError;

  Future<bool> _run(Future<void> Function() action) async {
    if (_busy) return false;
    setState(() {
      _busy = true;
      _operationError = null;
    });
    var succeeded = false;
    try {
      await action();
      ref.invalidate(v2GameDetailProvider(widget.sessionId));
      succeeded = true;
    } catch (error) {
      if (mounted) {
        setState(() => _operationError = _friendlyError(error));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    return succeeded;
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
              !appBarDetail.game.isFinalized &&
              appBarDetail.game.phase != 'cancelled')
            IconButton(
              tooltip: 'Cancel game',
              onPressed: () => _cancelGame(appBarDetail),
              icon: const Icon(Icons.cancel_outlined),
            ),
          IconButton(
            tooltip: 'Refresh',
            onPressed: () =>
                ref.invalidate(v2GameDetailProvider(widget.sessionId)),
            icon: const Icon(Icons.refresh),
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
          final visibleStep = detail.game.isDraft
              ? _draftStep
              : detail.game.isLive
              ? (_showSummary ? 3 : 2)
              : 3;
          return Column(
            children: [
              _GameProgress(
                currentStep: visibleStep,
                game: detail.game,
                onStepPressed: (step) {
                  if (detail.game.isDraft && step <= 1) {
                    setState(() => _draftStep = step);
                  } else if (detail.game.isLive && step >= 2) {
                    setState(() => _showSummary = step == 3);
                  }
                },
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
                    onInvite: () => _showInviteSearch(detail),
                    onCreateCode: () => _showJoinCode(detail),
                    onRespond: (id, accept) =>
                        _run(() => repository.respondToInvitation(id, accept)),
                    onSetBackup: (participant) => _run(
                      () => repository.setBackupHost(
                        widget.sessionId,
                        participant.profileId!,
                      ),
                    ),
                    onContinue: detail.participants.length >= 2 && isHost
                        ? () => setState(() => _draftStep = 1)
                        : null,
                  ),
                  1 => _ModePage(
                    detail: detail,
                    isHost: isHost,
                    settlementMode: _settlementMode,
                    bankerParticipantId: _bankerParticipantId,
                    onModeChanged: (mode) => setState(() {
                      _settlementMode = mode;
                      if (mode == 'pairwise') {
                        _bankerParticipantId = null;
                        _paidUpfrontParticipantIds.clear();
                      }
                    }),
                    onBankerChanged: (id) => setState(() {
                      _bankerParticipantId = id;
                      if (id != null) {
                        _paidUpfrontParticipantIds.remove(id);
                      }
                    }),
                    paidUpfrontParticipantIds: _paidUpfrontParticipantIds,
                    onPaidUpfrontChanged: (id, paid) => setState(() {
                      if (paid) {
                        _paidUpfrontParticipantIds.add(id);
                      } else {
                        _paidUpfrontParticipantIds.remove(id);
                      }
                    }),
                    onBack: () => setState(() => _draftStep = 0),
                    onStart:
                        isHost &&
                            (_settlementMode == 'pairwise' ||
                                _bankerParticipantId != null)
                        ? () => _run(
                            () => repository.startGame(
                              sessionId: widget.sessionId,
                              settlementMode: _settlementMode!,
                              bankerParticipantId: _bankerParticipantId,
                              paidUpfrontParticipantIds:
                                  _paidUpfrontParticipantIds,
                            ),
                          )
                        : null,
                  ),
                  2 => _LivePage(
                    detail: detail,
                    isHost: isHost,
                    onRebuy: (participant) =>
                        _recordMoney(participant, cashOut: false),
                    onReverse: (event) => _reverseEvent(event),
                    onInvite: () => _showInviteSearch(detail),
                    onCreateCode: () => _showJoinCode(detail),
                    onRespond: (id, accept) =>
                        _run(() => repository.respondToInvitation(id, accept)),
                    onReview: () => _reviewGame(detail, isHost),
                  ),
                  _ => _SummaryPage(
                    detail: detail,
                    isHost: isHost,
                    onBackToGame: detail.game.isSettling && isHost
                        ? _returnToLive
                        : detail.game.isLive
                        ? () => setState(() => _showSummary = false)
                        : null,
                    onCashOut: isHost && detail.game.isSettling
                        ? (participant) =>
                              _recordMoney(participant, cashOut: true)
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
                  ),
                },
              ),
            ],
          );
        },
      ),
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

  Future<void> _showJoinCode(V2GameDetail detail) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Generate a new join code?'),
        content: const Text(
          'Any earlier code for this game will stop working. The new code '
          'expires in two hours, and you still approve every request.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Keep current code'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Generate'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await _run(() async {
      final result = await ref
          .read(v2GameRepositoryProvider)
          .createJoinCode(widget.sessionId);
      if (!mounted) return;
      final code = result['code'] as String;
      await showDialog<void>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('Game join code'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SelectableText(
                code,
                style: Theme.of(context).textTheme.displaySmall?.copyWith(
                  fontWeight: FontWeight.bold,
                  letterSpacing: 6,
                ),
              ),
              const SizedBox(height: 12),
              const Text(
                'Expires in two hours. Players enter this code in Poker Ledger; '
                'you still approve each request.',
                textAlign: TextAlign.center,
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () async {
                await SharePlus.instance.share(
                  ShareParams(
                    text:
                        'Join ${detail.game.name ?? 'my poker game'} in '
                        'Poker Ledger with code $code.\n'
                        'io.supabase.pokerledger://join/$code',
                  ),
                );
              },
              child: const Text('Share'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Done'),
            ),
          ],
        ),
      );
    });
  }

  Future<void> _recordMoney(
    V2Participant participant, {
    required bool cashOut,
  }) async {
    final amount = await showDialog<int>(
      context: context,
      builder: (_) => _MoneyDialog(
        title: cashOut
            ? 'Cash out ${participant.displayName}'
            : 'Rebuy for ${participant.displayName}',
      ),
    );
    if (amount == null) return;
    final repository = ref.read(v2GameRepositoryProvider);
    await _run(
      () => cashOut
          ? repository.cashOut(
              sessionId: widget.sessionId,
              participantId: participant.id,
              amountCents: amount,
            )
          : repository.addRebuy(
              sessionId: widget.sessionId,
              participantId: participant.id,
              amountCents: amount,
            ),
    );
  }

  Future<void> _reverseEvent(V2LedgerEvent event) async {
    final controller = TextEditingController();
    final reason = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Reverse ledger entry?'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: 'Reason',
            hintText: 'Explain what was entered incorrectly',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              final reason = controller.text.trim();
              if (reason.isNotEmpty) Navigator.pop(dialogContext, reason);
            },
            child: const Text('Reverse'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (reason == null) return;
    await _run(
      () => ref
          .read(v2GameRepositoryProvider)
          .reverseEvent(
            sessionId: widget.sessionId,
            event: event,
            reason: reason,
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
    if (mounted) setState(() => _showSummary = true);
  }

  Future<void> _returnToLive() async {
    final controller = TextEditingController();
    final reason = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Return to the live ledger?'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: 'Reason',
            hintText: 'Example: missed rebuy',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              final value = controller.text.trim();
              if (value.isNotEmpty) Navigator.pop(dialogContext, value);
            },
            child: const Text('Return to live'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (reason == null) return;
    final returned = await _run(
      () => ref
          .read(v2GameRepositoryProvider)
          .returnToLive(widget.sessionId, reason),
    );
    if (returned && mounted) setState(() => _showSummary = false);
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
    final controller = TextEditingController();
    final reason = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Cancel this game?'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'Cancellation reason'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Keep game'),
          ),
          FilledButton(
            onPressed: () {
              final value = controller.text.trim();
              if (value.isNotEmpty) Navigator.pop(dialogContext, value);
            },
            child: const Text('Cancel game'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (reason == null) return;
    await _run(
      () =>
          ref.read(v2GameRepositoryProvider).cancelGame(detail.game.id, reason),
    );
  }
}

class _GameProgress extends StatelessWidget {
  final int currentStep;
  final V2Game game;
  final ValueChanged<int> onStepPressed;

  const _GameProgress({
    required this.currentStep,
    required this.game,
    required this.onStepPressed,
  });

  @override
  Widget build(BuildContext context) {
    const labels = ['Lobby', 'Mode', 'Live', 'Summary'];
    return Semantics(
      label: 'Game progress: ${labels[currentStep]}',
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
        child: Row(
          children: List.generate(labels.length, (index) {
            final complete = index < currentStep;
            final active = index == currentStep;
            final canOpen = game.isDraft
                ? index <= 1
                : game.isLive
                ? index >= 2
                : index == 3;
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

class _LobbyPage extends StatelessWidget {
  final V2GameDetail detail;
  final bool isHost;
  final VoidCallback onInvite;
  final VoidCallback onCreateCode;
  final void Function(String id, bool accept) onRespond;
  final ValueChanged<V2Participant> onSetBackup;
  final VoidCallback? onContinue;

  const _LobbyPage({
    required this.detail,
    required this.isHost,
    required this.onInvite,
    required this.onCreateCode,
    required this.onRespond,
    required this.onSetBackup,
    required this.onContinue,
  });

  @override
  Widget build(BuildContext context) {
    final joinRequests = detail.invitations.where(
      (invitation) => invitation.awaitingHost,
    );
    final sentInvitations = detail.invitations.where(
      (invitation) => invitation.status == 'pending_invitee',
    );
    final remaining = (2 - detail.participants.length).clamp(0, 2);
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text('Game lobby', style: Theme.of(context).textTheme.headlineSmall),
        const SizedBox(height: 4),
        Text(
          isHost
              ? 'Invite account-backed players. Everyone explicitly accepts '
                    'before they are added.'
              : 'Waiting for the host to start the game.',
        ),
        const SizedBox(height: 20),
        Text(
          'Accepted players (${detail.participants.length})',
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: 8),
        ...detail.participants.map(
          (participant) => Card(
            child: ListTile(
              leading: const CircleAvatar(child: Icon(Icons.person)),
              title: Text(participant.displayName),
              subtitle: Text(
                participant.profileId == detail.game.backupHostId
                    ? 'Accepted · Backup host'
                    : 'Accepted',
              ),
              trailing:
                  isHost &&
                      participant.profileId != null &&
                      participant.profileId != detail.game.currentHostId
                  ? IconButton(
                      tooltip: 'Assign backup host',
                      onPressed: () => onSetBackup(participant),
                      icon: Icon(
                        participant.profileId == detail.game.backupHostId
                            ? Icons.verified_user
                            : Icons.person_add_alt_1,
                      ),
                    )
                  : const Icon(Icons.check_circle, color: Colors.green),
            ),
          ),
        ),
        if (joinRequests.isNotEmpty) ...[
          const SizedBox(height: 16),
          Text('Join requests', style: Theme.of(context).textTheme.titleMedium),
          ...joinRequests.map(
            (invitation) => Card(
              child: ListTile(
                title: Text(invitation.displayName),
                subtitle: Text(
                  invitation.handle == null
                      ? 'Requested to join'
                      : '@${invitation.handle}',
                ),
                trailing: Wrap(
                  children: [
                    IconButton(
                      tooltip: 'Decline',
                      onPressed: () => onRespond(invitation.id, false),
                      icon: const Icon(Icons.close),
                    ),
                    IconButton(
                      tooltip: 'Accept',
                      onPressed: () => onRespond(invitation.id, true),
                      icon: const Icon(Icons.check),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
        if (sentInvitations.isNotEmpty) ...[
          const SizedBox(height: 16),
          Text(
            'Waiting for a response',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          ...sentInvitations.map(
            (invitation) => ListTile(
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
        if (isHost) ...[
          const SizedBox(height: 20),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: onInvite,
                  icon: const Icon(Icons.person_search),
                  label: const Text('Invite by handle'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: onCreateCode,
                  icon: const Icon(Icons.password),
                  label: const Text('Generate code'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 24),
          FilledButton(
            onPressed: onContinue,
            child: Text(
              onContinue == null
                  ? 'Add $remaining more player${remaining == 1 ? '' : 's'}'
                  : 'Choose settlement mode',
            ),
          ),
        ],
      ],
    );
  }
}

class _ModePage extends StatelessWidget {
  final V2GameDetail detail;
  final bool isHost;
  final String? settlementMode;
  final int? bankerParticipantId;
  final ValueChanged<String> onModeChanged;
  final ValueChanged<int?> onBankerChanged;
  final Set<int> paidUpfrontParticipantIds;
  final void Function(int id, bool paid) onPaidUpfrontChanged;
  final VoidCallback onBack;
  final VoidCallback? onStart;

  const _ModePage({
    required this.detail,
    required this.isHost,
    required this.settlementMode,
    required this.bankerParticipantId,
    required this.onModeChanged,
    required this.onBankerChanged,
    required this.paidUpfrontParticipantIds,
    required this.onPaidUpfrontChanged,
    required this.onBack,
    required this.onStart,
  });

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text(
          'How will players settle?',
          style: Theme.of(context).textTheme.headlineSmall,
        ),
        const SizedBox(height: 4),
        const Text(
          'This checkpoint must be completed before any buy-in is recorded.',
        ),
        const SizedBox(height: 20),
        RadioGroup<String>(
          groupValue: settlementMode,
          onChanged: (value) {
            if (isHost && value != null) onModeChanged(value);
          },
          child: const Column(
            children: [
              RadioListTile(
                value: 'pairwise',
                title: Text('Pairwise'),
                subtitle: Text(
                  'Create a small set of direct payments between players.',
                ),
              ),
              RadioListTile(
                value: 'banker',
                title: Text('Banker'),
                subtitle: Text(
                  'Every payment goes through one selected player.',
                ),
              ),
            ],
          ),
        ),
        if (settlementMode == 'banker') ...[
          const SizedBox(height: 12),
          DropdownButtonFormField<int>(
            initialValue: bankerParticipantId,
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
            onChanged: isHost ? onBankerChanged : null,
          ),
          if (bankerParticipantId != null) ...[
            const SizedBox(height: 20),
            Text(
              'Already paid the banker',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const Text(
              'Mark only payments already completed before the game starts.',
            ),
            ...detail.participants
                .where((participant) => participant.id != bankerParticipantId)
                .map(
                  (participant) => CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    value: paidUpfrontParticipantIds.contains(participant.id),
                    onChanged: isHost
                        ? (value) => onPaidUpfrontChanged(
                            participant.id,
                            value ?? false,
                          )
                        : null,
                    title: Text(participant.displayName),
                  ),
                ),
          ],
        ],
        const SizedBox(height: 24),
        Row(
          children: [
            OutlinedButton(onPressed: onBack, child: const Text('Back')),
            const SizedBox(width: 12),
            Expanded(
              child: FilledButton.icon(
                onPressed: onStart,
                icon: const Icon(Icons.play_arrow),
                label: Text(
                  onStart == null
                      ? settlementMode == null && isHost
                            ? 'Choose a settlement mode'
                            : settlementMode == 'banker'
                            ? 'Choose a banker'
                            : 'Waiting for host'
                      : 'Start live game',
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _LivePage extends StatelessWidget {
  final V2GameDetail detail;
  final bool isHost;
  final ValueChanged<V2Participant> onRebuy;
  final ValueChanged<V2LedgerEvent> onReverse;
  final VoidCallback onInvite;
  final VoidCallback onCreateCode;
  final void Function(String id, bool accept) onRespond;
  final VoidCallback onReview;

  const _LivePage({
    required this.detail,
    required this.isHost,
    required this.onRebuy,
    required this.onReverse,
    required this.onInvite,
    required this.onCreateCode,
    required this.onRespond,
    required this.onReview,
  });

  @override
  Widget build(BuildContext context) {
    final joinRequests = detail.invitations.where(
      (invitation) => invitation.awaitingHost,
    );
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text('Live game', style: Theme.of(context).textTheme.headlineSmall),
        const SizedBox(height: 4),
        Text(
          isHost
              ? 'Record rebuys as they happen. End the game to enter cash-outs.'
              : 'The host is recording this game. Pull to refresh for updates.',
        ),
        const SizedBox(height: 16),
        if (isHost) ...[
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: onInvite,
                  icon: const Icon(Icons.person_add_alt_1),
                  label: const Text('Invite player'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: onCreateCode,
                  icon: const Icon(Icons.password),
                  label: const Text('Generate code'),
                ),
              ),
            ],
          ),
          if (joinRequests.isNotEmpty) ...[
            const SizedBox(height: 16),
            Text(
              'Join requests',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            ...joinRequests.map(
              (invitation) => ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(invitation.displayName),
                subtitle: invitation.handle == null
                    ? const Text('Requested to join')
                    : Text('@${invitation.handle}'),
                trailing: Wrap(
                  children: [
                    IconButton(
                      tooltip: 'Decline',
                      onPressed: () => onRespond(invitation.id, false),
                      icon: const Icon(Icons.close),
                    ),
                    IconButton(
                      tooltip: 'Accept',
                      onPressed: () => onRespond(invitation.id, true),
                      icon: const Icon(Icons.check),
                    ),
                  ],
                ),
              ),
            ),
          ],
          const SizedBox(height: 16),
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
          return Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          participant.displayName,
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                      ),
                      if (activeCashOut)
                        const Chip(
                          avatar: Icon(Icons.check, size: 16),
                          label: Text('Cashed out'),
                        ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Buy-ins ${Money.formatCents(totals.buyInsCents, symbol: '\$')}'
                    '${activeCashOut ? '  •  Cash-out ${Money.formatCents(totals.cashOutCents, symbol: '\$')}' : ''}',
                  ),
                  if (isHost) ...[
                    const SizedBox(height: 12),
                    OutlinedButton.icon(
                      onPressed: activeCashOut
                          ? null
                          : () => onRebuy(participant),
                      icon: const Icon(Icons.add),
                      label: const Text('Add rebuy'),
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
            subtitle: const Text(
              'Incorrect entries are reversed, never erased.',
            ),
            children: detail.events.reversed.map((event) {
              final participant = detail.participants.firstWhere(
                (item) => item.id == event.participantId,
              );
              final alreadyReversed = detail.events.any(
                (other) => other.reversesEventId == event.id,
              );
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
                    Text(Money.formatCents(event.amountCents, symbol: '\$')),
                    IconButton(
                      tooltip: alreadyReversed ? 'Already reversed' : 'Reverse',
                      onPressed: alreadyReversed
                          ? null
                          : () => onReverse(event),
                      icon: const Icon(Icons.undo),
                    ),
                  ],
                ),
              );
            }).toList(),
          ),
        const SizedBox(height: 20),
        FilledButton(
          onPressed: onReview,
          child: Text(
            isHost ? 'End game & enter cash-outs' : 'Review progress',
          ),
        ),
      ],
    );
  }
}

class _SummaryPage extends StatelessWidget {
  final V2GameDetail detail;
  final bool isHost;
  final VoidCallback? onBackToGame;
  final ValueChanged<V2Participant>? onCashOut;
  final VoidCallback? onFinalize;
  final VoidCallback onShare;
  final VoidCallback onExport;
  final VoidCallback onPdf;
  final String currentUserId;
  final void Function(V2SettlementTransfer transfer, String status)
  onTransferStatus;
  final VoidCallback? onCorrect;

  const _SummaryPage({
    required this.detail,
    required this.isHost,
    required this.onBackToGame,
    required this.onCashOut,
    required this.onFinalize,
    required this.onShare,
    required this.onExport,
    required this.onPdf,
    required this.currentUserId,
    required this.onTransferStatus,
    required this.onCorrect,
  });

  @override
  Widget build(BuildContext context) {
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
        ? _previewTransfers(detail)
        : const <SettlementTransfer>[];
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text(
          detail.game.isFinalized ? 'Final summary' : 'Review game',
          style: Theme.of(context).textTheme.headlineSmall,
        ),
        const SizedBox(height: 4),
        Text(
          detail.game.isFinalized
              ? 'Revision ${detail.game.latestRevisionId ?? ''} is locked and auditable.'
              : 'Complete each required item before finalizing.',
        ),
        const SizedBox(height: 16),
        ...detail.participants.map((participant) {
          final totals = detail.totalsFor(participant.id);
          final needsCashOut = missingCashOuts.contains(participant);
          return Card(
            child: Column(
              children: [
                ListTile(
                  title: Text(participant.displayName),
                  subtitle: Text(
                    'Buy-ins ${Money.formatCents(totals.buyInsCents, symbol: '\$')} • '
                    'Cash-out ${needsCashOut ? 'not entered' : Money.formatCents(totals.cashOutCents, symbol: '\$')}',
                  ),
                  trailing: needsCashOut
                      ? const Icon(Icons.radio_button_unchecked)
                      : Text(
                          Money.formatCents(totals.netCents, symbol: '\$'),
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            color: totals.netCents > 0
                                ? Colors.green
                                : totals.netCents < 0
                                ? Theme.of(context).colorScheme.error
                                : null,
                          ),
                        ),
                ),
                if (needsCashOut && onCashOut != null)
                  Align(
                    alignment: Alignment.centerRight,
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                      child: FilledButton.tonalIcon(
                        onPressed: () => onCashOut!(participant),
                        icon: const Icon(Icons.logout),
                        label: const Text('Enter cash-out'),
                      ),
                    ),
                  ),
              ],
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
          Text('Settlement', style: Theme.of(context).textTheme.titleMedium),
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
                    title: Text('${from.displayName} pays ${to.displayName}'),
                    subtitle: Text('Status: ${transfer.status}'),
                    trailing: Text(
                      Money.formatCents(transfer.amountCents, symbol: '\$'),
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
                          if (isPayer && transfer.status != 'paid')
                            TextButton(
                              onPressed: () =>
                                  onTransferStatus(transfer, 'paid'),
                              child: const Text('Mark paid'),
                            ),
                          if (isRecipient && transfer.status == 'paid')
                            FilledButton.tonal(
                              onPressed: () =>
                                  onTransferStatus(transfer, 'received'),
                              child: const Text('Confirm received'),
                            ),
                          TextButton(
                            onPressed: () =>
                                onTransferStatus(transfer, 'disputed'),
                            child: const Text('Dispute'),
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
        if (onBackToGame != null)
          OutlinedButton(
            onPressed: onBackToGame,
            child: const Text('Back to live game'),
          ),
        if (!detail.game.isFinalized)
          FilledButton(
            onPressed: onFinalize,
            child: Text(
              onFinalize != null
                  ? 'Finalize game'
                  : isHost
                  ? 'Complete the items above'
                  : 'Waiting for host',
            ),
          ),
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

List<SettlementTransfer> _previewTransfers(V2GameDetail detail) {
  try {
    if (detail.game.settlementMode == 'banker' &&
        detail.game.bankerParticipantId != null) {
      return SettlementEngine.settleBanker(
        participants: detail.participants.map((participant) {
          final totals = detail.totalsFor(participant.id);
          return BankerSettlementParticipant(
            participantId: participant.id,
            buyInCents: totals.buyInsCents,
            cashOutCents: totals.cashOutCents,
            paidUpfront: participant.paidUpfront,
          );
        }),
        bankerParticipantId: detail.game.bankerParticipantId!,
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
  final text = error.toString().toLowerCase();
  if (text.contains('compatible client') || text.contains('upgrade')) {
    return 'Update Poker Ledger before changing this game.';
  }
  if (text.contains('permission') ||
      text.contains('row-level security') ||
      text.contains('42501')) {
    return 'You have read-only access to this game.';
  }
  if (text.contains('balance') || text.contains('buy-ins and cash-outs')) {
    return 'Buy-ins and cash-outs must balance exactly before finalizing.';
  }
  if (text.contains('cash-out') && text.contains('required')) {
    return 'Enter and save every cash-out before finalizing.';
  }
  if (text.contains('expired') || text.contains('join code')) {
    return 'This join code is invalid, expired, or revoked.';
  }
  if (text.contains('backup host')) {
    return 'Choose an accepted participant who is eligible to host this game.';
  }
  if (text.contains('network') ||
      text.contains('socket') ||
      text.contains('connection')) {
    return 'Check your connection and try again.';
  }
  return 'The change could not be saved. Refresh and try again.';
}
