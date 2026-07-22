import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'session_repository.dart';

final sessionRepositoryProvider = Provider<SessionRepository>(
  (ref) => SessionRepository(),
);
