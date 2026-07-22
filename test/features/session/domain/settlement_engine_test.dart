import 'package:flutter_test/flutter_test.dart';
import 'package:poker_ledger/src/features/session/domain/settlement_engine.dart';

void main() {
  group('SettlementEngine metadata', () {
    test('publishes the algorithm version on results', () {
      final result = SettlementEngine.settlePairwise(const []);

      expect(settlementEngineVersion, 1);
      expect(SettlementEngine.version, settlementEngineVersion);
      expect(result.version, settlementEngineVersion);
      expect(result.mode, SettlementMode.pairwise);
    });
  });

  group('pairwise settlement', () {
    test('settles a zero-sum set and exposes zero residuals', () {
      final result = SettlementEngine.settlePairwise(const [
        SettlementBalance(participantId: 1, netCents: -5000),
        SettlementBalance(participantId: 2, netCents: 3000),
        SettlementBalance(participantId: 3, netCents: 2000),
      ]);

      expect(result.transfers, const [
        SettlementTransfer(
          fromParticipantId: 1,
          toParticipantId: 2,
          amountCents: 3000,
        ),
        SettlementTransfer(
          fromParticipantId: 1,
          toParticipantId: 3,
          amountCents: 2000,
        ),
      ]);
      expect(result.residuals, const [
        SettlementResidual(participantId: 1, amountCents: 0),
        SettlementResidual(participantId: 2, amountCents: 0),
        SettlementResidual(participantId: 3, amountCents: 0),
      ]);
      expect(result.isFullySettled, isTrue);
      expect(result.totalTransferredCents, 5000);
    });

    test('uses deterministic participant ID tie-breakers', () {
      const canonicalInput = [
        SettlementBalance(participantId: 1, netCents: -800),
        SettlementBalance(participantId: 2, netCents: -200),
        SettlementBalance(participantId: 3, netCents: 500),
        SettlementBalance(participantId: 4, netCents: 500),
      ];
      const permutedInput = [
        SettlementBalance(participantId: 4, netCents: 500),
        SettlementBalance(participantId: 2, netCents: -200),
        SettlementBalance(participantId: 3, netCents: 500),
        SettlementBalance(participantId: 1, netCents: -800),
      ];

      final first = SettlementEngine.settlePairwise(canonicalInput);
      final second = SettlementEngine.settlePairwise(permutedInput);

      const expected = [
        SettlementTransfer(
          fromParticipantId: 1,
          toParticipantId: 3,
          amountCents: 500,
        ),
        SettlementTransfer(
          fromParticipantId: 1,
          toParticipantId: 4,
          amountCents: 300,
        ),
        SettlementTransfer(
          fromParticipantId: 2,
          toParticipantId: 4,
          amountCents: 200,
        ),
      ];
      expect(first.transfers, expected);
      expect(second.transfers, expected);
      expect(second.residuals, first.residuals);
    });

    test('settles one-cent and large integer-cent edges exactly', () {
      const largeAmount = 1 << 50;
      final result = SettlementEngine.settlePairwise(const [
        SettlementBalance(participantId: 1, netCents: -largeAmount),
        SettlementBalance(participantId: 2, netCents: largeAmount - 1),
        SettlementBalance(participantId: 3, netCents: 1),
      ]);

      expect(result.transfers, const [
        SettlementTransfer(
          fromParticipantId: 1,
          toParticipantId: 2,
          amountCents: largeAmount - 1,
        ),
        SettlementTransfer(
          fromParticipantId: 1,
          toParticipantId: 3,
          amountCents: 1,
        ),
      ]);
      expect(result.isFullySettled, isTrue);
    });

    test('returns no transfers for empty and all-even inputs', () {
      final empty = SettlementEngine.settlePairwise(const []);
      final even = SettlementEngine.settlePairwise(const [
        SettlementBalance(participantId: 8, netCents: 0),
        SettlementBalance(participantId: 4, netCents: 0),
      ]);

      expect(empty.transfers, isEmpty);
      expect(empty.residuals, isEmpty);
      expect(empty.isFullySettled, isTrue);
      expect(even.transfers, isEmpty);
      expect(even.residuals, const [
        SettlementResidual(participantId: 4, amountCents: 0),
        SettlementResidual(participantId: 8, amountCents: 0),
      ]);
    });

    test('rejects non-zero participant net balances', () {
      expect(
        () => SettlementEngine.settlePairwise(const [
          SettlementBalance(participantId: 1, netCents: -100),
          SettlementBalance(participantId: 2, netCents: 99),
        ]),
        throwsA(
          isA<SettlementValidationException>().having(
            (error) => error.message,
            'message',
            contains('found -1 cents'),
          ),
        ),
      );
    });

    test('rejects duplicate participant IDs', () {
      expect(
        () => SettlementEngine.settlePairwise(const [
          SettlementBalance(participantId: 7, netCents: -100),
          SettlementBalance(participantId: 7, netCents: 100),
        ]),
        throwsA(isA<SettlementValidationException>()),
      );
    });

    test('returns immutable transfer and residual collections', () {
      final result = SettlementEngine.settlePairwise(const [
        SettlementBalance(participantId: 1, netCents: -1),
        SettlementBalance(participantId: 2, netCents: 1),
      ]);

      expect(
        () => result.transfers.add(
          const SettlementTransfer(
            fromParticipantId: 1,
            toParticipantId: 2,
            amountCents: 1,
          ),
        ),
        throwsUnsupportedError,
      );
      expect(() => result.residuals.clear(), throwsUnsupportedError);
    });
  });

  group('banker settlement', () {
    test('settles unpaid participants against the banker by net', () {
      final result = SettlementEngine.settleBanker(
        bankerParticipantId: 1,
        participants: const [
          BankerSettlementParticipant(
            participantId: 1,
            buyInCents: 1000,
            cashOutCents: 500,
            paidUpfront: false,
          ),
          BankerSettlementParticipant(
            participantId: 2,
            buyInCents: 1000,
            cashOutCents: 1500,
            paidUpfront: false,
          ),
        ],
      );

      expect(result.mode, SettlementMode.banker);
      expect(result.transfers, const [
        SettlementTransfer(
          fromParticipantId: 1,
          toParticipantId: 2,
          amountCents: 500,
        ),
      ]);
      expect(result.isFullySettled, isTrue);
    });

    test('pays a paid-upfront participant their full cash-out', () {
      final result = SettlementEngine.settleBanker(
        bankerParticipantId: 1,
        participants: const [
          BankerSettlementParticipant(
            participantId: 1,
            buyInCents: 3000,
            cashOutCents: 2000,
            paidUpfront: false,
          ),
          BankerSettlementParticipant(
            participantId: 2,
            buyInCents: 1000,
            cashOutCents: 2000,
            paidUpfront: true,
          ),
        ],
      );

      expect(result.transfers, const [
        SettlementTransfer(
          fromParticipantId: 1,
          toParticipantId: 2,
          amountCents: 2000,
        ),
      ]);
      expect(result.totalTransferredCents, 2000);
    });

    test('handles mixed paid-upfront states', () {
      final result = SettlementEngine.settleBanker(
        bankerParticipantId: 1,
        participants: const [
          BankerSettlementParticipant(
            participantId: 1,
            buyInCents: 10000,
            cashOutCents: 9000,
            paidUpfront: false,
          ),
          BankerSettlementParticipant(
            participantId: 2,
            buyInCents: 5000,
            cashOutCents: 7000,
            paidUpfront: true,
          ),
          BankerSettlementParticipant(
            participantId: 3,
            buyInCents: 5000,
            cashOutCents: 4000,
            paidUpfront: false,
          ),
        ],
      );

      expect(result.transfers, const [
        SettlementTransfer(
          fromParticipantId: 1,
          toParticipantId: 2,
          amountCents: 7000,
        ),
        SettlementTransfer(
          fromParticipantId: 3,
          toParticipantId: 1,
          amountCents: 1000,
        ),
      ]);
      expect(result.residuals, const [
        SettlementResidual(participantId: 1, amountCents: 0),
        SettlementResidual(participantId: 2, amountCents: 0),
        SettlementResidual(participantId: 3, amountCents: 0),
      ]);
    });

    test('returns a losing paid-upfront player remaining cash-out', () {
      final result = SettlementEngine.settleBanker(
        bankerParticipantId: 10,
        participants: const [
          BankerSettlementParticipant(
            participantId: 10,
            buyInCents: 1000,
            cashOutCents: 4000,
            paidUpfront: false,
          ),
          BankerSettlementParticipant(
            participantId: 20,
            buyInCents: 5000,
            cashOutCents: 2000,
            paidUpfront: true,
          ),
        ],
      );

      expect(
        result.transfers.single,
        const SettlementTransfer(
          fromParticipantId: 10,
          toParticipantId: 20,
          amountCents: 2000,
        ),
      );
    });

    test('is deterministic and omits even participants', () {
      const ordered = [
        BankerSettlementParticipant(
          participantId: 30,
          buyInCents: 1000,
          cashOutCents: 500,
          paidUpfront: false,
        ),
        BankerSettlementParticipant(
          participantId: 10,
          buyInCents: 1000,
          cashOutCents: 1500,
          paidUpfront: false,
        ),
        BankerSettlementParticipant(
          participantId: 20,
          buyInCents: 1000,
          cashOutCents: 1000,
          paidUpfront: false,
        ),
      ];
      const permuted = [
        BankerSettlementParticipant(
          participantId: 20,
          buyInCents: 1000,
          cashOutCents: 1000,
          paidUpfront: false,
        ),
        BankerSettlementParticipant(
          participantId: 10,
          buyInCents: 1000,
          cashOutCents: 1500,
          paidUpfront: false,
        ),
        BankerSettlementParticipant(
          participantId: 30,
          buyInCents: 1000,
          cashOutCents: 500,
          paidUpfront: false,
        ),
      ];

      final first = SettlementEngine.settleBanker(
        bankerParticipantId: 30,
        participants: ordered,
      );
      final second = SettlementEngine.settleBanker(
        bankerParticipantId: 30,
        participants: permuted,
      );

      expect(second.transfers, first.transfers);
      expect(first.transfers, const [
        SettlementTransfer(
          fromParticipantId: 30,
          toParticipantId: 10,
          amountCents: 500,
        ),
      ]);
      expect(first.residuals, second.residuals);
    });

    test('rejects non-zero original poker balances', () {
      expect(
        () => SettlementEngine.settleBanker(
          bankerParticipantId: 1,
          participants: const [
            BankerSettlementParticipant(
              participantId: 1,
              buyInCents: 1000,
              cashOutCents: 1000,
              paidUpfront: false,
            ),
            BankerSettlementParticipant(
              participantId: 2,
              buyInCents: 1000,
              cashOutCents: 1001,
              paidUpfront: true,
            ),
          ],
        ),
        throwsA(
          isA<SettlementValidationException>().having(
            (error) => error.message,
            'message',
            contains('found 1 cents'),
          ),
        ),
      );
    });

    test('rejects a missing banker', () {
      expect(
        () => SettlementEngine.settleBanker(
          bankerParticipantId: 99,
          participants: const [
            BankerSettlementParticipant(
              participantId: 1,
              buyInCents: 1000,
              cashOutCents: 1000,
              paidUpfront: false,
            ),
          ],
        ),
        throwsA(
          isA<SettlementValidationException>().having(
            (error) => error.message,
            'message',
            contains('Banker participant 99 is missing'),
          ),
        ),
      );
    });

    test('rejects duplicate IDs and negative monetary values', () {
      expect(
        () => SettlementEngine.settleBanker(
          bankerParticipantId: 1,
          participants: const [
            BankerSettlementParticipant(
              participantId: 1,
              buyInCents: 0,
              cashOutCents: 0,
              paidUpfront: false,
            ),
            BankerSettlementParticipant(
              participantId: 1,
              buyInCents: 0,
              cashOutCents: 0,
              paidUpfront: false,
            ),
          ],
        ),
        throwsA(isA<SettlementValidationException>()),
      );

      expect(
        () => SettlementEngine.settleBanker(
          bankerParticipantId: 1,
          participants: const [
            BankerSettlementParticipant(
              participantId: 1,
              buyInCents: -1,
              cashOutCents: 0,
              paidUpfront: false,
            ),
          ],
        ),
        throwsA(
          isA<SettlementValidationException>().having(
            (error) => error.message,
            'message',
            contains('non-negative integer cents'),
          ),
        ),
      );
    });
  });
}
