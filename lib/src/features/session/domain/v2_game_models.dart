class V2Game {
  final int id;
  final String? name;
  final DateTime startedAt;
  final DateTime? endedAt;
  final String phase;
  final String settlementMode;
  final int? bankerParticipantId;
  final int? groupId;
  final String ownerId;
  final String? currentHostId;
  final String? backupHostId;
  final bool canEdit;
  final String currencyCode;
  final int defaultBuyInCents;
  final int? latestRevisionId;

  const V2Game({
    required this.id,
    required this.name,
    required this.startedAt,
    required this.endedAt,
    required this.phase,
    required this.settlementMode,
    required this.bankerParticipantId,
    required this.groupId,
    required this.ownerId,
    required this.currentHostId,
    required this.backupHostId,
    required this.canEdit,
    required this.currencyCode,
    required this.defaultBuyInCents,
    required this.latestRevisionId,
  });

  bool get isDraft => phase == 'draft';
  bool get isLive => phase == 'live';
  bool get isSettling => phase == 'settling';
  bool get isFinalized => phase == 'finalized';

  factory V2Game.fromMap(Map<String, dynamic> map) => V2Game(
    id: _asInt(map['id'])!,
    name: map['name'] as String?,
    startedAt: DateTime.parse(map['started_at'] as String),
    endedAt: map['ended_at'] == null
        ? null
        : DateTime.parse(map['ended_at'] as String),
    phase: map['phase'] as String? ?? 'draft',
    settlementMode: map['settlement_mode'] as String? ?? 'pairwise',
    bankerParticipantId: _asInt(map['banker_session_player_id']),
    groupId: _asInt(map['group_id']),
    ownerId: map['user_id'] as String,
    currentHostId: map['current_host_id'] as String?,
    backupHostId: map['backup_host_id'] as String?,
    canEdit: map['can_edit'] as bool? ?? false,
    currencyCode: map['currency_code'] as String? ?? 'USD',
    defaultBuyInCents: _asInt(map['default_buy_in_cents']) ?? 0,
    latestRevisionId: _asInt(map['latest_revision_id']),
  );
}

class V2Participant {
  final int id;
  final String? profileId;
  final String displayName;
  final bool paidUpfront;
  final int? chosenBuyInCents;
  final DateTime? acceptedAt;
  final DateTime? removedAt;
  final DateTime? eliminatedAt;

  const V2Participant({
    required this.id,
    required this.profileId,
    required this.displayName,
    required this.paidUpfront,
    required this.chosenBuyInCents,
    required this.acceptedAt,
    required this.removedAt,
    required this.eliminatedAt,
  });

  bool get isOut => eliminatedAt != null;

  factory V2Participant.fromMap(Map<String, dynamic> map) => V2Participant(
    id: _asInt(map['id'])!,
    profileId: map['profile_id'] as String?,
    displayName: map['display_name_snapshot'] as String? ?? 'Deleted player',
    paidUpfront: map['paid_upfront'] as bool? ?? false,
    chosenBuyInCents: _asInt(map['chosen_buy_in_cents']),
    acceptedAt: map['accepted_at'] == null
        ? null
        : DateTime.parse(map['accepted_at'] as String),
    removedAt: map['removed_at'] == null
        ? null
        : DateTime.parse(map['removed_at'] as String),
    eliminatedAt: map['eliminated_at'] == null
        ? null
        : DateTime.parse(map['eliminated_at'] as String),
  );
}

class V2LedgerEvent {
  final int id;
  final int sequence;
  final int participantId;
  final String type;
  final int amountCents;
  final String? actorSnapshot;
  final String? reason;
  final int? reversesEventId;
  final DateTime createdAt;

  const V2LedgerEvent({
    required this.id,
    required this.sequence,
    required this.participantId,
    required this.type,
    required this.amountCents,
    required this.actorSnapshot,
    required this.reason,
    required this.reversesEventId,
    required this.createdAt,
  });

  factory V2LedgerEvent.fromMap(Map<String, dynamic> map) => V2LedgerEvent(
    id: _asInt(map['id'])!,
    sequence: _asInt(map['event_sequence'])!,
    participantId: _asInt(map['participant_id'])!,
    type: map['event_type'] as String,
    amountCents: _asInt(map['amount_cents'])!,
    actorSnapshot: map['actor_snapshot'] as String?,
    reason: map['reason'] as String?,
    reversesEventId: _asInt(map['reverses_event_id']),
    createdAt: DateTime.parse(map['created_at'] as String),
  );
}

class V2Invitation {
  final String id;
  final int sessionId;
  final String profileId;
  final String direction;
  final String status;
  final DateTime expiresAt;
  final String displayName;
  final String? handle;

  const V2Invitation({
    required this.id,
    required this.sessionId,
    required this.profileId,
    required this.direction,
    required this.status,
    required this.expiresAt,
    required this.displayName,
    required this.handle,
  });

  bool get awaitingCurrentInvitee =>
      direction == 'host_invite' && status == 'pending_invitee';
  bool get awaitingHost =>
      direction == 'join_request' && status == 'pending_host';
  bool get awaitingBuyIn => status == 'accepted_pending_buy_in';

  factory V2Invitation.fromMap(Map<String, dynamic> map) {
    final profile = map['profiles'] as Map<String, dynamic>?;
    return V2Invitation(
      id: map['id'] as String,
      sessionId: _asInt(map['session_id'])!,
      profileId: map['profile_id'] as String,
      direction: map['direction'] as String,
      status: map['status'] as String,
      expiresAt: _parseExpiresAt(map['expires_at']),
      displayName: profile?['display_name'] as String? ?? 'Poker Ledger player',
      handle: profile?['handle'] as String?,
    );
  }
}

class V2SettlementTransfer {
  final int id;
  final int fromParticipantId;
  final int toParticipantId;
  final int amountCents;
  final String status;
  final List<V2TransferStatusChange> statusHistory;

  const V2SettlementTransfer({
    required this.id,
    required this.fromParticipantId,
    required this.toParticipantId,
    required this.amountCents,
    required this.status,
    required this.statusHistory,
  });

  factory V2SettlementTransfer.fromMap(Map<String, dynamic> map) =>
      V2SettlementTransfer(
        id: _asInt(map['id'])!,
        fromParticipantId: _asInt(map['from_participant_id'])!,
        toParticipantId: _asInt(map['to_participant_id'])!,
        amountCents: _asInt(map['amount_cents'])!,
        status: map['status'] as String? ?? 'pending',
        statusHistory:
            (map['settlement_transfer_status_history'] as List? ?? const [])
                .map(
                  (row) => V2TransferStatusChange.fromMap(
                    Map<String, dynamic>.from(row as Map),
                  ),
                )
                .toList(),
      );
}

class OpenSettlementTransfer {
  final int transferId;
  final int sessionId;
  final String gameName;
  final int amountCents;
  final String status;
  final String direction;
  final String counterpartyName;
  final int fromParticipantId;
  final int toParticipantId;
  final int myParticipantId;

  const OpenSettlementTransfer({
    required this.transferId,
    required this.sessionId,
    required this.gameName,
    required this.amountCents,
    required this.status,
    required this.direction,
    required this.counterpartyName,
    required this.fromParticipantId,
    required this.toParticipantId,
    required this.myParticipantId,
  });

  bool get isOwe => direction == 'owe';
  bool get isOwed => direction == 'owed';
  bool get canMarkPaid => status == 'pending' || status == 'disputed';
  bool get canConfirmReceived => isOwed && status == 'paid';

  factory OpenSettlementTransfer.fromMap(Map<String, dynamic> map) =>
      OpenSettlementTransfer(
        transferId: _asInt(map['transfer_id'])!,
        sessionId: _asInt(map['session_id'])!,
        gameName: map['game_name'] as String? ?? 'Poker game',
        amountCents: _asInt(map['amount_cents']) ?? 0,
        status: map['status'] as String? ?? 'pending',
        direction: map['direction'] as String? ?? 'owe',
        counterpartyName: map['counterparty_name'] as String? ?? 'Player',
        fromParticipantId: _asInt(map['from_participant_id'])!,
        toParticipantId: _asInt(map['to_participant_id'])!,
        myParticipantId: _asInt(map['my_participant_id'])!,
      );
}

class V2TransferStatusChange {
  final String previousStatus;
  final String newStatus;
  final String actorSnapshot;
  final DateTime changedAt;

  const V2TransferStatusChange({
    required this.previousStatus,
    required this.newStatus,
    required this.actorSnapshot,
    required this.changedAt,
  });

  factory V2TransferStatusChange.fromMap(Map<String, dynamic> map) =>
      V2TransferStatusChange(
        previousStatus: map['previous_status'] as String,
        newStatus: map['new_status'] as String,
        actorSnapshot: map['changed_by_snapshot'] as String? ?? 'Deleted user',
        changedAt: DateTime.parse(map['changed_at'] as String),
      );
}

class V2GameDetail {
  final V2Game game;
  final List<V2Participant> participants;
  final List<V2LedgerEvent> events;
  final List<V2Invitation> invitations;
  final List<V2FinalizationRevision> revisions;
  final List<V2SettlementTransfer> transfers;

  const V2GameDetail({
    required this.game,
    required this.participants,
    required this.events,
    required this.invitations,
    required this.revisions,
    required this.transfers,
  });

  V2ParticipantTotals totalsFor(int participantId) {
    var buyIns = 0;
    var cashOut = 0;
    var signedTotal = 0;
    final eventById = {for (final event in events) event.id: event};
    for (final event in events.where(
      (event) => event.participantId == participantId,
    )) {
      signedTotal += event.amountCents;
      if (event.type == 'initial_buy_in' || event.type == 'rebuy') {
        buyIns += event.amountCents;
      } else if (event.type == 'cash_out') {
        cashOut += -event.amountCents;
      } else if (event.type == 'correction') {
        if (event.amountCents > 0) {
          buyIns += event.amountCents;
        } else {
          cashOut += -event.amountCents;
        }
      } else if (event.type == 'reversal' && event.reversesEventId != null) {
        final original = eventById[event.reversesEventId];
        if (original != null && original.amountCents > 0) {
          buyIns += event.amountCents;
        } else if (original != null && original.amountCents < 0) {
          cashOut += -event.amountCents;
        }
      }
    }
    return V2ParticipantTotals(
      buyInsCents: buyIns,
      cashOutCents: cashOut,
      netCents: -signedTotal,
    );
  }

  bool get everyPlayerCashedOut =>
      participants.isNotEmpty &&
      participants.every(
        (participant) => events.any(
          (event) =>
              event.participantId == participant.id &&
              event.type == 'cash_out' &&
              !events.any((other) => other.reversesEventId == event.id),
        ),
      );

  int get ledgerBalanceCents =>
      events.fold(0, (total, event) => total + event.amountCents);
}

class V2FinalizationRevision {
  final int id;
  final int revisionNumber;
  final int throughEventSequence;
  final String settlementMode;
  final int totalBuyInCents;
  final int totalCashOutCents;
  final String? reason;
  final DateTime createdAt;
  final DateTime? supersededAt;

  const V2FinalizationRevision({
    required this.id,
    required this.revisionNumber,
    required this.throughEventSequence,
    required this.settlementMode,
    required this.totalBuyInCents,
    required this.totalCashOutCents,
    required this.reason,
    required this.createdAt,
    required this.supersededAt,
  });

  factory V2FinalizationRevision.fromMap(Map<String, dynamic> map) =>
      V2FinalizationRevision(
        id: _asInt(map['id'])!,
        revisionNumber: _asInt(map['revision_number'])!,
        throughEventSequence: _asInt(map['through_event_sequence'])!,
        settlementMode: map['settlement_mode'] as String,
        totalBuyInCents: _asInt(map['total_buy_in_cents'])!,
        totalCashOutCents: _asInt(map['total_cash_out_cents'])!,
        reason: map['reason'] as String?,
        createdAt: DateTime.parse(map['created_at'] as String),
        supersededAt: map['superseded_at'] == null
            ? null
            : DateTime.parse(map['superseded_at'] as String),
      );
}

class V2ParticipantTotals {
  final int buyInsCents;
  final int cashOutCents;
  final int netCents;

  const V2ParticipantTotals({
    required this.buyInsCents,
    required this.cashOutCents,
    required this.netCents,
  });
}

class DiscoverableProfile {
  final String id;
  final String handle;
  final String displayName;
  final String? avatarUrl;
  final String resultState;

  const DiscoverableProfile({
    required this.id,
    required this.handle,
    required this.displayName,
    required this.avatarUrl,
    required this.resultState,
  });

  bool get canInvite =>
      resultState == 'not_in_game' || resultState == 'not_in_group';

  factory DiscoverableProfile.fromMap(Map<String, dynamic> map) =>
      DiscoverableProfile(
        id: map['id'] as String,
        handle: map['handle'] as String,
        displayName: map['display_name'] as String? ?? map['handle'] as String,
        avatarUrl: map['avatar_url'] as String?,
        resultState: map['result_state'] as String? ?? 'not_in_game',
      );
}

int? _asInt(Object? value) {
  if (value == null) return null;
  if (value is int) return value;
  return int.tryParse(value.toString());
}

DateTime _parseExpiresAt(Object? value) {
  if (value == null) {
    return DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
  }
  final text = value.toString().trim().toLowerCase();
  if (text == 'infinity' || text == '+infinity') {
    return DateTime.utc(9999, 12, 31);
  }
  if (text == '-infinity') {
    return DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
  }
  return DateTime.parse(value.toString());
}
