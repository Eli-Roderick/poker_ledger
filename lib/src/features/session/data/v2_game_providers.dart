import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/v2_game_models.dart';
import 'v2_game_repository.dart';

final v2GameRepositoryProvider = Provider<V2GameRepository>(
  (_) => V2GameRepository(),
);

final v2GameDetailProvider = FutureProvider.autoDispose
    .family<V2GameDetail, int>((ref, sessionId) {
      return ref.watch(v2GameRepositoryProvider).getGame(sessionId);
    });

final pendingGameInvitationsProvider =
    FutureProvider.autoDispose<List<V2Invitation>>((ref) {
      return ref
          .watch(v2GameRepositoryProvider)
          .pendingInvitationsForCurrentUser();
    });

final openSettlementTransfersProvider =
    FutureProvider.autoDispose<List<OpenSettlementTransfer>>((ref) {
      return ref.watch(v2GameRepositoryProvider).myOpenSettlementTransfers();
    });
