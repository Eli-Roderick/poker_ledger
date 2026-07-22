import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../auth/providers/auth_providers.dart';

const requiredBackendContractVersion = 1;

class BackendCompatibilityException implements Exception {
  final String message;
  final Object? cause;

  const BackendCompatibilityException(this.message, {this.cause});

  @override
  String toString() => message;
}

bool isMissingBackendRpc(PostgrestException error) => error.code == 'PGRST202';

Never backendCompatibilityFailure(PostgrestException error) {
  throw BackendCompatibilityException(
    'The Poker Ledger backend must be updated before this feature can load.',
    cause: error,
  );
}

final backendContractProvider = FutureProvider<void>((ref) async {
  final user = ref.watch(currentUserProvider);
  if (user == null) return;

  try {
    final result = await Supabase.instance.client.rpc(
      'poker_ledger_backend_contract',
    );
    final version = result is int ? result : int.tryParse(result.toString());
    if (version == null || version < requiredBackendContractVersion) {
      throw const BackendCompatibilityException(
        'This app requires a newer Poker Ledger backend.',
      );
    }
  } on PostgrestException catch (error) {
    if (isMissingBackendRpc(error)) {
      backendCompatibilityFailure(error);
    }
    rethrow;
  }
});
