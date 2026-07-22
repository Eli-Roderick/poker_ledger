/// Version of the canonical settlement algorithm and its output contract.
const int settlementEngineVersion = 1;

/// The settlement strategy used to produce a [SettlementResult].
enum SettlementMode { pairwise, banker }

/// A participant's final poker balance in integer cents.
///
/// A positive balance must be received and a negative balance must be paid.
final class SettlementBalance {
  final int participantId;
  final int netCents;

  const SettlementBalance({
    required this.participantId,
    required this.netCents,
  });
}

/// The information needed to settle a participant through a banker.
///
/// [paidUpfront] indicates that the participant already paid their buy-ins to
/// the banker. Such a participant receives their entire cash-out at settlement.
/// A participant who did not pay upfront settles only their net result.
final class BankerSettlementParticipant {
  final int participantId;
  final int buyInCents;
  final int cashOutCents;
  final bool paidUpfront;

  const BankerSettlementParticipant({
    required this.participantId,
    required this.buyInCents,
    required this.cashOutCents,
    required this.paidUpfront,
  });

  int get netCents => cashOutCents - buyInCents;
}

/// A positive integer-cent payment from one participant to another.
final class SettlementTransfer {
  final int fromParticipantId;
  final int toParticipantId;
  final int amountCents;

  const SettlementTransfer({
    required this.fromParticipantId,
    required this.toParticipantId,
    required this.amountCents,
  });

  @override
  bool operator ==(Object other) =>
      other is SettlementTransfer &&
      other.fromParticipantId == fromParticipantId &&
      other.toParticipantId == toParticipantId &&
      other.amountCents == amountCents;

  @override
  int get hashCode =>
      Object.hash(fromParticipantId, toParticipantId, amountCents);

  @override
  String toString() =>
      'SettlementTransfer($fromParticipantId -> $toParticipantId: '
      '$amountCents cents)';
}

/// The amount still due after applying all returned transfers.
///
/// Positive cents mean the participant is still owed money; negative cents
/// mean they still owe money. A valid completed settlement has only zero
/// residuals.
final class SettlementResidual {
  final int participantId;
  final int amountCents;

  const SettlementResidual({
    required this.participantId,
    required this.amountCents,
  });

  @override
  bool operator ==(Object other) =>
      other is SettlementResidual &&
      other.participantId == participantId &&
      other.amountCents == amountCents;

  @override
  int get hashCode => Object.hash(participantId, amountCents);

  @override
  String toString() => 'SettlementResidual($participantId: $amountCents cents)';
}

/// Immutable output from the canonical settlement engine.
final class SettlementResult {
  final int version;
  final SettlementMode mode;
  final List<SettlementTransfer> transfers;
  final List<SettlementResidual> residuals;

  SettlementResult._({
    required this.mode,
    required List<SettlementTransfer> transfers,
    required List<SettlementResidual> residuals,
  }) : version = settlementEngineVersion,
       transfers = List.unmodifiable(transfers),
       residuals = List.unmodifiable(residuals);

  bool get isFullySettled =>
      residuals.every((residual) => residual.amountCents == 0);

  int get totalTransferredCents =>
      transfers.fold(0, (total, transfer) => total + transfer.amountCents);
}

/// Thrown when settlement input is ambiguous or financially inconsistent.
final class SettlementValidationException implements Exception {
  final String message;

  const SettlementValidationException(this.message);

  @override
  String toString() => 'SettlementValidationException: $message';
}

/// Pure-Dart, deterministic settlement calculations using integer cents only.
final class SettlementEngine {
  const SettlementEngine._();

  static const int version = settlementEngineVersion;

  /// Minimizes pairwise debts with a deterministic largest-balance-first pass.
  ///
  /// Participant IDs break equal-value ties, so input iteration order never
  /// affects the returned transfers.
  static SettlementResult settlePairwise(Iterable<SettlementBalance> balances) {
    final input = List<SettlementBalance>.of(balances);
    _validateUniqueIds(input.map((balance) => balance.participantId));
    _validateZeroSum(input.map((balance) => balance.netCents));

    final debtors = <_OpenBalance>[];
    final creditors = <_OpenBalance>[];
    final openingBalances = <int, int>{};

    for (final balance in input) {
      openingBalances[balance.participantId] = balance.netCents;
      if (balance.netCents < 0) {
        debtors.add(_OpenBalance(balance.participantId, -balance.netCents));
      } else if (balance.netCents > 0) {
        creditors.add(_OpenBalance(balance.participantId, balance.netCents));
      }
    }

    debtors.sort(_compareOpenBalances);
    creditors.sort(_compareOpenBalances);

    final transfers = <SettlementTransfer>[];
    var debtorIndex = 0;
    var creditorIndex = 0;

    while (debtorIndex < debtors.length && creditorIndex < creditors.length) {
      final debtor = debtors[debtorIndex];
      final creditor = creditors[creditorIndex];
      final amount = debtor.amountCents < creditor.amountCents
          ? debtor.amountCents
          : creditor.amountCents;

      transfers.add(
        SettlementTransfer(
          fromParticipantId: debtor.participantId,
          toParticipantId: creditor.participantId,
          amountCents: amount,
        ),
      );

      debtor.amountCents -= amount;
      creditor.amountCents -= amount;
      if (debtor.amountCents == 0) debtorIndex++;
      if (creditor.amountCents == 0) creditorIndex++;
    }

    return _result(
      mode: SettlementMode.pairwise,
      openingBalances: openingBalances,
      transfers: transfers,
    );
  }

  /// Settles every non-banker participant directly with [bankerParticipantId].
  ///
  /// Before producing transfers, the original poker nets (cash-out minus
  /// buy-ins) are validated as zero-sum. Paid-upfront state then determines the
  /// amount that remains to be exchanged:
  ///
  /// * paid upfront: banker pays the participant's full cash-out;
  /// * not paid upfront: participant and banker exchange the participant's net.
  static SettlementResult settleBanker({
    required Iterable<BankerSettlementParticipant> participants,
    required int bankerParticipantId,
  }) {
    final input = List<BankerSettlementParticipant>.of(participants);
    _validateUniqueIds(input.map((participant) => participant.participantId));

    for (final participant in input) {
      if (participant.buyInCents < 0 || participant.cashOutCents < 0) {
        throw SettlementValidationException(
          'Buy-ins and cash-outs must be non-negative integer cents.',
        );
      }
    }

    if (!input.any(
      (participant) => participant.participantId == bankerParticipantId,
    )) {
      throw SettlementValidationException(
        'Banker participant $bankerParticipantId is missing.',
      );
    }

    _validateZeroSum(input.map((participant) => participant.netCents));
    input.sort((a, b) => a.participantId.compareTo(b.participantId));

    final openingBalances = <int, int>{};
    var nonBankerTotal = 0;

    for (final participant in input) {
      if (participant.participantId == bankerParticipantId) continue;
      final amount = participant.paidUpfront
          ? participant.cashOutCents
          : participant.netCents;
      openingBalances[participant.participantId] = amount;
      nonBankerTotal += amount;
    }
    openingBalances[bankerParticipantId] = -nonBankerTotal;

    final transfers = <SettlementTransfer>[];
    for (final participant in input) {
      if (participant.participantId == bankerParticipantId) continue;
      final amount = openingBalances[participant.participantId]!;
      if (amount > 0) {
        transfers.add(
          SettlementTransfer(
            fromParticipantId: bankerParticipantId,
            toParticipantId: participant.participantId,
            amountCents: amount,
          ),
        );
      } else if (amount < 0) {
        transfers.add(
          SettlementTransfer(
            fromParticipantId: participant.participantId,
            toParticipantId: bankerParticipantId,
            amountCents: -amount,
          ),
        );
      }
    }

    return _result(
      mode: SettlementMode.banker,
      openingBalances: openingBalances,
      transfers: transfers,
    );
  }

  static void _validateUniqueIds(Iterable<int> participantIds) {
    final seen = <int>{};
    for (final participantId in participantIds) {
      if (!seen.add(participantId)) {
        throw SettlementValidationException(
          'Duplicate participant ID: $participantId.',
        );
      }
    }
  }

  static void _validateZeroSum(Iterable<int> netBalances) {
    final total = netBalances.fold<int>(0, (sum, balance) => sum + balance);
    if (total != 0) {
      throw SettlementValidationException(
        'Participant net balances must sum to zero cents; found $total cents.',
      );
    }
  }

  static SettlementResult _result({
    required SettlementMode mode,
    required Map<int, int> openingBalances,
    required List<SettlementTransfer> transfers,
  }) {
    final remaining = Map<int, int>.of(openingBalances);
    for (final transfer in transfers) {
      remaining[transfer.fromParticipantId] =
          remaining[transfer.fromParticipantId]! + transfer.amountCents;
      remaining[transfer.toParticipantId] =
          remaining[transfer.toParticipantId]! - transfer.amountCents;
    }

    final residuals =
        remaining.entries
            .map(
              (entry) => SettlementResidual(
                participantId: entry.key,
                amountCents: entry.value,
              ),
            )
            .toList()
          ..sort((a, b) => a.participantId.compareTo(b.participantId));

    return SettlementResult._(
      mode: mode,
      transfers: transfers,
      residuals: residuals,
    );
  }

  static int _compareOpenBalances(_OpenBalance a, _OpenBalance b) {
    final amountOrder = b.amountCents.compareTo(a.amountCents);
    return amountOrder != 0
        ? amountOrder
        : a.participantId.compareTo(b.participantId);
  }
}

final class _OpenBalance {
  final int participantId;
  int amountCents;

  _OpenBalance(this.participantId, this.amountCents);
}
