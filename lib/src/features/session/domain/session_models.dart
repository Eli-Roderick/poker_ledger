class Session {
  final int? id;
  final String? name;
  final DateTime startedAt;
  final DateTime? endedAt;
  final bool finalized;
  final String settlementMode; // 'pairwise' or 'banker'
  final int? bankerSessionPlayerId;

  const Session({
    this.id,
    this.name,
    required this.startedAt,
    this.endedAt,
    this.finalized = false,
    this.settlementMode = 'pairwise',
    this.bankerSessionPlayerId,
  });

  Map<String, Object?> toMap() => {
        'id': id,
        'name': name,
        'started_at': startedAt.millisecondsSinceEpoch,
        'ended_at': endedAt?.millisecondsSinceEpoch,
        'finalized': finalized ? 1 : 0,
        'settlement_mode': settlementMode,
        'banker_session_player_id': bankerSessionPlayerId,
      };

  factory Session.fromMap(Map<String, Object?> map) => Session(
        id: map['id'] as int?,
        name: map['name'] as String?,
        startedAt: DateTime.fromMillisecondsSinceEpoch(map['started_at'] as int),
        endedAt: map['ended_at'] == null
            ? null
            : DateTime.fromMillisecondsSinceEpoch(map['ended_at'] as int),
        finalized: (map['finalized'] as int) == 1,
        settlementMode: (map['settlement_mode'] as String?) ?? 'pairwise',
        bankerSessionPlayerId: map['banker_session_player_id'] as int?,
      );
}

class SessionPlayer {
  final int? id;
  final int sessionId;
  final int playerId;
  final int buyInCentsTotal; // includes initial + rebuys
  final int? cashOutCents; // nullable until entered
  final bool paidUpfront;
  final bool settlementDone;

  const SessionPlayer({
    this.id,
    required this.sessionId,
    required this.playerId,
    required this.buyInCentsTotal,
    this.cashOutCents,
    required this.paidUpfront,
    this.settlementDone = false,
  });

  Map<String, Object?> toMap() => {
        'id': id,
        'session_id': sessionId,
        'player_id': playerId,
        'buy_in_cents_total': buyInCentsTotal,
        'cash_out_cents': cashOutCents,
        'paid_upfront': paidUpfront ? 1 : 0,
        'settlement_done': settlementDone ? 1 : 0,
      };

  factory SessionPlayer.fromMap(Map<String, Object?> map) => SessionPlayer(
        id: map['id'] as int?,
        sessionId: map['session_id'] as int,
        playerId: map['player_id'] as int,
        buyInCentsTotal: map['buy_in_cents_total'] as int,
        cashOutCents: map['cash_out_cents'] as int?,
        paidUpfront: (map['paid_upfront'] as int) == 1,
        settlementDone: ((map['settlement_done'] as int?) ?? 0) == 1,
      );
}

class RebuyEntry {
  final int? id;
  final int sessionPlayerId;
  final int amountCents;
  final DateTime createdAt;

  const RebuyEntry({this.id, required this.sessionPlayerId, required this.amountCents, required this.createdAt});

  Map<String, Object?> toMap() => {
        'id': id,
        'session_player_id': sessionPlayerId,
        'amount_cents': amountCents,
        'created_at': createdAt.millisecondsSinceEpoch,
      };

  factory RebuyEntry.fromMap(Map<String, Object?> map) => RebuyEntry(
        id: map['id'] as int?,
        sessionPlayerId: map['session_player_id'] as int,
        amountCents: map['amount_cents'] as int,
        createdAt: DateTime.fromMillisecondsSinceEpoch(map['created_at'] as int),
      );
}
