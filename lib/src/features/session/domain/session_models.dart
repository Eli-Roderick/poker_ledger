/// Represents a poker session (game night).
/// 
/// A session tracks a single poker game from start to finish, including:
/// - All participating players and their buy-ins/cash-outs
/// - Settlement mode (pairwise or banker)
/// - Finalization status (locked when complete)
/// 
/// Sessions can be shared to groups for collaborative stat tracking.
class Session {
  final int? id;
  final String? name;
  final DateTime startedAt;
  final DateTime? endedAt;
  
  /// True when the session is complete and locked for editing
  final bool finalized;
  
  /// Settlement mode: 'pairwise' (everyone settles with everyone) or 'banker' (one person handles all)
  final String settlementMode;
  
  /// The session_player ID of the banker (only used in banker mode)
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

/// Represents a player's participation in a specific session.
/// 
/// Tracks the financial details for one player in one session:
/// - Buy-ins (initial + rebuys combined)
/// - Cash-out (entered when player leaves)
/// - Settlement status (for tracking who has paid/received)
class SessionPlayer {
  final int? id;
  final int sessionId;
  final int playerId;
  
  /// Total buy-in amount in cents (includes initial buy-in + all rebuys)
  final int buyInCentsTotal;
  
  /// Cash-out amount in cents (null until player cashes out)
  final int? cashOutCents;
  
  /// True if player paid their buy-in upfront (affects settlement calculations)
  final bool paidUpfront;
  
  /// True if this player's settlement is complete
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
  final String? sharedByName; // For group sessions - who shared it to the group
  final bool canRemoveFromGroup; // Whether current user can remove this session from the group

  const SessionWithOwner({
    required this.session,
    required this.ownerName,
    required this.isOwner,
    this.sharedByName,
    this.canRemoveFromGroup = false,
  });
}
