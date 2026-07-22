import 'package:flutter_test/flutter_test.dart';
import 'package:poker_ledger/src/config/backend_contract.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  test('recognizes a missing PostgREST RPC as a compatibility failure', () {
    const error = PostgrestException(
      message: 'Function was not found',
      code: 'PGRST202',
    );

    expect(isMissingBackendRpc(error), isTrue);
  });

  test('does not classify ordinary backend errors as missing contracts', () {
    const error = PostgrestException(
      message: 'Permission denied',
      code: '42501',
    );

    expect(isMissingBackendRpc(error), isFalse);
  });
}
