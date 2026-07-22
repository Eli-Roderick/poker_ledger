import 'package:flutter_test/flutter_test.dart';
import 'package:poker_ledger/src/features/session/domain/v2_game_models.dart';

void main() {
  V2LedgerEvent event({
    required int id,
    required String type,
    required int amount,
    int? reverses,
  }) {
    return V2LedgerEvent.fromMap({
      'id': id,
      'event_sequence': id,
      'participant_id': 10,
      'event_type': type,
      'amount_cents': amount,
      'actor_snapshot': 'Host snapshot',
      'reason': null,
      'reverses_event_id': reverses,
      'created_at': '2026-07-20T12:00:00Z',
    });
  }

  test('totals include signed corrections and exact reversal pairs', () {
    final detail = V2GameDetail(
      game: V2Game.fromMap({
        'id': 1,
        'user_id': 'host',
        'current_host_id': 'host',
        'name': 'Test',
        'group_id': null,
        'phase': 'settling',
        'settlement_mode': 'pairwise',
        'banker_participant_id': null,
        'default_buy_in_cents': 1000,
        'membership_closed_at': '2026-07-20T12:00:00Z',
        'latest_revision_id': null,
        'started_at': '2026-07-20T12:00:00Z',
        'ended_at': null,
        'groups': null,
      }),
      participants: [
        V2Participant.fromMap({
          'id': 10,
          'profile_id': 'player',
          'display_name_snapshot': 'Historical name',
          'paid_upfront': false,
          'accepted_at': '2026-07-20T12:00:00Z',
          'removed_at': null,
        }),
      ],
      events: [
        event(id: 1, type: 'initial_buy_in', amount: 1000),
        event(id: 2, type: 'rebuy', amount: 500),
        event(id: 3, type: 'reversal', amount: -500, reverses: 2),
        event(id: 4, type: 'correction', amount: 200),
        event(id: 5, type: 'cash_out', amount: -1200),
      ],
      invitations: const [],
      revisions: const [],
      transfers: const [],
    );

    final totals = detail.totalsFor(10);
    expect(totals.buyInsCents, 1200);
    expect(totals.cashOutCents, 1200);
    expect(totals.netCents, 0);
    expect(detail.ledgerBalanceCents, 0);
    expect(detail.everyPlayerCashedOut, isTrue);
  });

  test('transfer status history preserves each actor snapshot', () {
    final transfer = V2SettlementTransfer.fromMap({
      'id': 1,
      'revision_id': 2,
      'from_participant_id': 10,
      'to_participant_id': 11,
      'amount_cents': 500,
      'status': 'received',
      'status_updated_at': '2026-07-20T13:00:00Z',
      'created_at': '2026-07-20T12:00:00Z',
      'settlement_transfer_status_history': [
        {
          'id': 1,
          'previous_status': 'pending',
          'new_status': 'paid',
          'changed_by_snapshot': 'Payer',
          'changed_at': '2026-07-20T12:30:00Z',
        },
        {
          'id': 2,
          'previous_status': 'paid',
          'new_status': 'received',
          'changed_by_snapshot': 'Recipient',
          'changed_at': '2026-07-20T13:00:00Z',
        },
      ],
    });

    expect(transfer.status, 'received');
    expect(transfer.statusHistory, hasLength(2));
    expect(transfer.statusHistory.last.actorSnapshot, 'Recipient');
  });
}
