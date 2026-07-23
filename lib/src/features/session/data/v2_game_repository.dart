import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../utils/idempotency_key.dart';
import '../domain/v2_game_models.dart';

class V2GameRepository {
  final SupabaseClient _client;

  V2GameRepository({SupabaseClient? client})
    : _client = client ?? Supabase.instance.client;

  String get currentUserId => _client.auth.currentUser!.id;

  Future<bool> isEnabledForCurrentUser() async {
    final response = await _client.rpc('v2_game_flow_available');
    return response == true;
  }

  Future<int> createGame({
    required String? name,
    required int? groupId,
    required int defaultBuyInCents,
    required bool hostParticipates,
    String currencyCode = 'USD',
  }) async {
    final response = await _client.rpc(
      'create_v2_session',
      params: {
        'p_name': name,
        'p_group_id': groupId,
        'p_default_buy_in_cents': defaultBuyInCents,
        'p_currency_code': currencyCode,
        'p_host_participates': hostParticipates,
        'p_idempotency_key': IdempotencyKey.generate(),
      },
    );
    return _asInt((response as Map)['session_id'])!;
  }

  Future<V2GameDetail> getGame(int sessionId) async {
    final results = await Future.wait<dynamic>(<Future<dynamic>>[
      _client
          .from('sessions')
          .select()
          .eq('id', sessionId)
          .eq('ledger_version', 2)
          .single(),
      _client
          .from('session_players')
          .select(
            'id, profile_id, display_name_snapshot, paid_upfront, '
            'chosen_buy_in_cents, accepted_at, removed_at, eliminated_at',
          )
          .eq('session_id', sessionId)
          .isFilter('removed_at', null)
          .order('id'),
      _client
          .from('ledger_events')
          .select(
            'id, event_sequence, participant_id, event_type, amount_cents, '
            'actor_snapshot, reason, reverses_event_id, created_at',
          )
          .eq('session_id', sessionId)
          .order('event_sequence'),
      _client
          .from('game_invitations')
          .select(
            'id, session_id, profile_id, direction, status, expires_at, '
            'profiles(display_name, handle)',
          )
          .eq('session_id', sessionId)
          .inFilter('status', [
            'pending_invitee',
            'pending_host',
            'accepted_pending_buy_in',
          ])
          .order('created_at'),
      _client
          .from('finalization_revisions')
          .select(
            'id, revision_number, through_event_sequence, settlement_mode, '
            'total_buy_in_cents, total_cash_out_cents, reason, created_at, '
            'superseded_at',
          )
          .eq('session_id', sessionId)
          .order('revision_number'),
      _client.rpc('can_edit_v2_session', params: {'p_session_id': sessionId}),
    ]);

    final gameMap = Map<String, dynamic>.from(results[0] as Map);
    gameMap['can_edit'] = results[5] == true;
    final game = V2Game.fromMap(gameMap);
    final participants = (results[1] as List)
        .map(
          (row) => V2Participant.fromMap(Map<String, dynamic>.from(row as Map)),
        )
        .toList();
    final events = (results[2] as List)
        .map(
          (row) => V2LedgerEvent.fromMap(Map<String, dynamic>.from(row as Map)),
        )
        .toList();
    final invitations = (results[3] as List)
        .map(
          (row) => V2Invitation.fromMap(Map<String, dynamic>.from(row as Map)),
        )
        .toList();
    final revisions = (results[4] as List)
        .map(
          (row) => V2FinalizationRevision.fromMap(
            Map<String, dynamic>.from(row as Map),
          ),
        )
        .toList();

    final transfers = game.latestRevisionId == null
        ? <V2SettlementTransfer>[]
        : await _loadTransfers(game.latestRevisionId!);
    return V2GameDetail(
      game: game,
      participants: participants,
      events: events,
      invitations: invitations,
      revisions: revisions,
      transfers: transfers,
    );
  }

  Future<List<V2SettlementTransfer>> _loadTransfers(int revisionId) async {
    final rows = await _client
        .from('settlement_transfers')
        .select(
          '*, settlement_transfer_status_history('
          'previous_status, new_status, changed_by_snapshot, changed_at)',
        )
        .eq('revision_id', revisionId)
        .order('id');
    return rows
        .map(
          (row) => V2SettlementTransfer.fromMap(Map<String, dynamic>.from(row)),
        )
        .toList();
  }

  Future<List<DiscoverableProfile>> searchProfiles(
    String query, {
    int? sessionId,
    int? groupId,
  }) async {
    final normalized = query.trim();
    if (normalized.length < 2) return [];
    final rows = await _client.rpc(
      'search_discoverable_profiles',
      params: {
        'search_text': normalized,
        'result_limit': 20,
        'for_session_id': sessionId,
        'for_group_id': groupId,
      },
    );
    return (rows as List)
        .map(
          (row) => DiscoverableProfile.fromMap(
            Map<String, dynamic>.from(row as Map),
          ),
        )
        .where((profile) => profile.id != currentUserId)
        .toList();
  }

  Future<void> inviteProfile(int sessionId, String profileId) async {
    await _client.rpc(
      'invite_profile_to_game',
      params: {
        'p_session_id': sessionId,
        'p_profile_id': profileId,
        'p_idempotency_key': IdempotencyKey.generate(),
      },
    );
  }

  Future<Map<String, dynamic>> createJoinCode(int sessionId) async {
    final response = await _client.rpc(
      'create_game_join_code',
      params: {
        'p_session_id': sessionId,
        'p_idempotency_key': IdempotencyKey.generate(),
      },
    );
    return Map<String, dynamic>.from(response as Map);
  }

  Future<Map<String, dynamic>> requestJoin(String code) async {
    final response = await _client.rpc(
      'request_game_join_by_code',
      params: {
        'p_code': code.trim(),
        'p_idempotency_key': IdempotencyKey.generate(),
      },
    );
    return Map<String, dynamic>.from(response as Map);
  }

  Future<void> respondToInvitation(String invitationId, bool accept) async {
    await _client.rpc(
      'respond_to_game_invitation',
      params: {
        'p_invitation_id': invitationId,
        'p_accept': accept,
        'p_idempotency_key': IdempotencyKey.generate(),
      },
    );
  }

  Future<void> setBuyIn({
    required int sessionId,
    required int participantId,
    required int amountCents,
  }) async {
    await _client.rpc(
      'set_v2_buy_in',
      params: {
        'p_session_id': sessionId,
        'p_participant_id': participantId,
        'p_amount_cents': amountCents,
        'p_idempotency_key': IdempotencyKey.generate(),
      },
    );
  }

  Future<JoinAcceptanceInfo> getJoinAcceptanceInfo(int sessionId) async {
    final response = await _client.rpc(
      'get_v2_join_acceptance_info',
      params: {'p_session_id': sessionId},
    );
    final map = Map<String, dynamic>.from(response as Map);
    return JoinAcceptanceInfo(
      sessionId: _asInt(map['session_id']) ?? sessionId,
      invitationId: map['invitation_id'] as String?,
      gameName: (map['game_name'] as String?)?.trim().isNotEmpty == true
          ? (map['game_name'] as String).trim()
          : 'Poker game',
      hostName: (map['host_name'] as String?)?.trim().isNotEmpty == true
          ? (map['host_name'] as String).trim()
          : 'Host',
      phase: map['phase'] as String? ?? 'draft',
      defaultBuyInCents: _asInt(map['default_buy_in_cents']) ?? 0,
      currencyCode: map['currency_code'] as String? ?? 'USD',
    );
  }

  Future<void> confirmJoinBuyIn({
    required String invitationId,
    required int amountCents,
  }) async {
    await _client.rpc(
      'confirm_game_join_buy_in',
      params: {
        'p_invitation_id': invitationId,
        'p_amount_cents': amountCents,
        'p_idempotency_key': IdempotencyKey.generate(),
      },
    );
  }

  Future<void> startGame({
    required int sessionId,
    required String settlementMode,
    required int? bankerParticipantId,
    Set<int> paidUpfrontParticipantIds = const {},
  }) async {
    // Keep null banker in the map so PostgREST resolves the 5-arg signature;
    // SQL also defaults p_banker_participant_id when the key is omitted.
    final params = <String, Object?>{
      'p_session_id': sessionId,
      'p_settlement_mode': settlementMode,
      'p_banker_participant_id': bankerParticipantId,
      'p_idempotency_key': IdempotencyKey.generate(),
      'p_paid_upfront_participant_ids': paidUpfrontParticipantIds.toList(),
    };
    await _client.rpc('start_v2_session', params: params);
  }

  Future<void> setSettlementPreferences({
    required int sessionId,
    required String settlementMode,
    required int? bankerParticipantId,
    Set<int> paidUpfrontParticipantIds = const {},
  }) async {
    await _client.rpc(
      'set_v2_settlement_preferences',
      params: {
        'p_session_id': sessionId,
        'p_settlement_mode': settlementMode,
        'p_banker_participant_id': bankerParticipantId,
        'p_idempotency_key': IdempotencyKey.generate(),
        'p_paid_upfront_participant_ids': paidUpfrontParticipantIds.toList(),
      },
    );
  }

  Future<void> addRebuy({
    required int sessionId,
    required int participantId,
    required int amountCents,
  }) => _recordEvent(
    sessionId: sessionId,
    participantId: participantId,
    type: 'rebuy',
    amountCents: amountCents,
  );

  Future<void> cashOut({
    required int sessionId,
    required int participantId,
    required int amountCents,
  }) => setCashOut(
    sessionId: sessionId,
    participantId: participantId,
    amountCents: amountCents,
  );

  Future<void> setCashOut({
    required int sessionId,
    required int participantId,
    required int amountCents,
  }) async {
    await _client.rpc(
      'set_v2_cash_out',
      params: {
        'p_session_id': sessionId,
        'p_participant_id': participantId,
        'p_amount_cents': amountCents,
        'p_idempotency_key': IdempotencyKey.generate(),
      },
    );
  }

  Future<void> setParticipantEliminated({
    required int sessionId,
    required int participantId,
    required bool eliminated,
  }) async {
    await _client.rpc(
      'set_v2_participant_eliminated',
      params: {
        'p_session_id': sessionId,
        'p_participant_id': participantId,
        'p_eliminated': eliminated,
        'p_idempotency_key': IdempotencyKey.generate(),
      },
    );
  }

  Future<void> deleteLedgerEvent({
    required int sessionId,
    required int eventId,
  }) async {
    await _client.rpc(
      'delete_v2_ledger_event',
      params: {
        'p_session_id': sessionId,
        'p_event_id': eventId,
        'p_idempotency_key': IdempotencyKey.generate(),
      },
    );
  }

  Future<void> beginSettlement(int sessionId) async {
    await _client.rpc(
      'begin_v2_settlement',
      params: {
        'p_session_id': sessionId,
        'p_idempotency_key': IdempotencyKey.generate(),
      },
    );
  }

  Future<void> returnToLive(int sessionId, String reason) async {
    await _client.rpc(
      'return_v2_session_to_live',
      params: {
        'p_session_id': sessionId,
        'p_reason': reason,
        'p_idempotency_key': IdempotencyKey.generate(),
      },
    );
  }

  Future<void> cancelGame(int sessionId, String reason) async {
    await _client.rpc(
      'cancel_v2_session',
      params: {
        'p_session_id': sessionId,
        'p_reason': reason,
        'p_idempotency_key': IdempotencyKey.generate(),
      },
    );
  }

  Future<void> leaveGame(int sessionId) async {
    await _client.rpc(
      'leave_v2_session',
      params: {
        'p_session_id': sessionId,
        'p_idempotency_key': IdempotencyKey.generate(),
      },
    );
  }

  Future<void> removeParticipant({
    required int sessionId,
    required int participantId,
  }) async {
    await _client.rpc(
      'remove_v2_participant',
      params: {
        'p_session_id': sessionId,
        'p_participant_id': participantId,
        'p_idempotency_key': IdempotencyKey.generate(),
      },
    );
  }

  Future<void> setBackupHost(int sessionId, String profileId) async {
    await _client.rpc(
      'set_v2_backup_host',
      params: {
        'p_session_id': sessionId,
        'p_profile_id': profileId,
        'p_idempotency_key': IdempotencyKey.generate(),
      },
    );
  }

  Future<void> reverseEvent({
    required int sessionId,
    required V2LedgerEvent event,
    required String reason,
  }) => _recordEvent(
    sessionId: sessionId,
    participantId: event.participantId,
    type: 'reversal',
    amountCents: -event.amountCents,
    reason: reason,
    reversesEventId: event.id,
  );

  Future<void> _recordEvent({
    required int sessionId,
    required int participantId,
    required String type,
    required int amountCents,
    String? reason,
    int? reversesEventId,
  }) async {
    await _client.rpc(
      'record_v2_ledger_event',
      params: {
        'p_session_id': sessionId,
        'p_participant_id': participantId,
        'p_event_type': type,
        'p_amount_cents': amountCents,
        'p_reason': reason,
        'p_reverses_event_id': reversesEventId,
        'p_idempotency_key': IdempotencyKey.generate(),
      },
    );
  }

  Future<void> finalizeGame(int sessionId, {String? reason}) async {
    await _client.rpc(
      'finalize_v2_session',
      params: {
        'p_session_id': sessionId,
        'p_reason': reason,
        'p_idempotency_key': IdempotencyKey.generate(),
      },
    );
  }

  Future<void> correctFinalizedGame({
    required int sessionId,
    required String reason,
    required List<Map<String, Object?>> corrections,
  }) async {
    await _client.rpc(
      'correct_finalized_v2_session',
      params: {
        'p_session_id': sessionId,
        'p_reason': reason,
        'p_corrections': corrections,
        'p_idempotency_key': IdempotencyKey.generate(),
      },
    );
  }

  Future<void> updateTransferStatus(int transferId, String status) async {
    await _client.rpc(
      'update_settlement_transfer_status',
      params: {
        'p_transfer_id': transferId,
        'p_status': status,
        'p_idempotency_key': IdempotencyKey.generate(),
      },
    );
  }

  Future<List<OpenSettlementTransfer>> myOpenSettlementTransfers() async {
    final rows = await _client.rpc('my_open_settlement_transfers');
    return (rows as List)
        .map(
          (row) => OpenSettlementTransfer.fromMap(
            Map<String, dynamic>.from(row as Map),
          ),
        )
        .toList();
  }

  Future<List<V2Invitation>> pendingInvitationsForCurrentUser() async {
    final rows = await _client
        .from('game_invitations')
        .select(
          'id, session_id, profile_id, direction, status, expires_at, '
          'profiles(display_name, handle)',
        )
        .eq('profile_id', currentUserId)
        .eq('status', 'pending_invitee')
        .gt('expires_at', DateTime.now().toIso8601String())
        .order('created_at', ascending: false);
    return rows
        .map((row) => V2Invitation.fromMap(Map<String, dynamic>.from(row)))
        .toList();
  }
}

class JoinAcceptanceInfo {
  final int sessionId;
  final String? invitationId;
  final String gameName;
  final String hostName;
  final String phase;
  final int defaultBuyInCents;
  final String currencyCode;

  const JoinAcceptanceInfo({
    required this.sessionId,
    required this.invitationId,
    required this.gameName,
    required this.hostName,
    required this.phase,
    required this.defaultBuyInCents,
    required this.currencyCode,
  });

  String get phaseLabel => switch (phase) {
    'draft' => 'Lobby',
    'live' => 'Live',
    'settling' => 'Summary',
    'finalized' => 'Finalized',
    _ => phase,
  };
}

int? _asInt(Object? value) {
  if (value == null) return null;
  if (value is int) return value;
  return int.tryParse(value.toString());
}
