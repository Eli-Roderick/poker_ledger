import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../data/app_settings_repository.dart';

final appSettingsRepositoryProvider = Provider<AppSettingsRepository>((ref) {
  return AppSettingsRepository();
});

final maintenanceModeProvider = StateNotifierProvider<MaintenanceModeNotifier, AsyncValue<bool>>((ref) {
  return MaintenanceModeNotifier(ref.read(appSettingsRepositoryProvider));
});

class MaintenanceModeNotifier extends StateNotifier<AsyncValue<bool>> {
  final AppSettingsRepository _repo;

  MaintenanceModeNotifier(this._repo) : super(const AsyncValue.loading()) {
    _load();
  }

  Future<void> _load() async {
    try {
      final enabled = await _repo.getMaintenanceMode();
      state = AsyncValue.data(enabled);
    } catch (e, st) {
      state = AsyncValue.error(e, st);
    }
  }

  Future<void> toggle() async {
    final current = state.valueOrNull ?? false;
    try {
      await _repo.setMaintenanceMode(!current);
      state = AsyncValue.data(!current);
    } catch (e, st) {
      state = AsyncValue.error(e, st);
    }
  }

  Future<void> refresh() async {
    await _load();
  }
}
