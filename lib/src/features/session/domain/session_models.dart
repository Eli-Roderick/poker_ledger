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
        'started_at': startedAt.toIso8601String(),
        'ended_at': endedAt?.toIso8601String(),
        'finalized': finalized,
        'settlement_mode': settlementMode,
        'banker_session_player_id': bankerSessionPlayerId,
      };

  factory Session.fromMap(Map<String, Object?> map) => Session(
        id: map['id'] is int ? map['id'] as int : int.tryParse(map['id'].toString()),
        name: map['name'] as String?,
        startedAt: DateTime.parse(map['started_at'] as String),
        endedAt: map['ended_at'] == null
            ? null
            : DateTime.parse(map['ended_at'] as String),
        finalized: map['finalized'] as bool? ?? false,
        settlementMode: (map['settlement_mode'] as String?) ?? 'pairwise',
        bankerSessionPlayerId: map['banker_session_player_id'] is int 
            ? map['banker_session_player_id'] as int 
            : (map['banker_session_player_id'] != null ? int.tryParse(map['banker_session_player_id'].toString()) : null),
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
        'paid_upfront': paidUpfront,
        'settlement_done': settlementDone,
      };

  factory SessionPlayer.fromMap(Map<String, Object?> map) => SessionPlayer(
        id: map['id'] is int ? map['id'] as int : int.tryParse(map['id'].toString()),
        sessionId: map['session_id'] is int ? map['session_id'] as int : int.parse(map['session_id'].toString()),
        playerId: map['player_id'] is int ? map['player_id'] as int : int.parse(map['player_id'].toString()),
        buyInCentsTotal: map['buy_in_cents_total'] as int? ?? 0,
        cashOutCents: map['cash_out_cents'] as int?,
        paidUpfront: map['paid_upfront'] as bool? ?? true,
        settlementDone: map['settlement_done'] as bool? ?? false,
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
        'created_at': createdAt.toIso8601String(),
      };

  factory RebuyEntry.fromMap(Map<String, Object?> map) => RebuyEntry(
        id: map['id'] is int ? map['id'] as int : int.tryParse(map['id'].toString()),
        sessionPlayerId: map['session_player_id'] is int ? map['session_player_id'] as int : int.parse(map['session_player_id'].toString()),
        amountCents: map['amount_cents'] as int,
        createdAt: DateTime.parse(map['created_at'] as String),
      );
}

class SessionWithOwner {
  final Session session;
  final String ownerName;
  final bool isOwner;

  const SessionWithOwner({
    required this.session,
    required this.ownerName,
    required this.isOwner,
  });
}
