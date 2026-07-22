import 'package:shared_preferences/shared_preferences.dart';

/// Which authenticated path the logged-out entry screen is showing.
enum AuthEntryMode { signIn, createAccount }

const authEntryModePreferenceKey = 'auth_entry_last_mode';

extension AuthEntryModeStorage on AuthEntryMode {
  String get storageValue => switch (this) {
    AuthEntryMode.signIn => 'signIn',
    AuthEntryMode.createAccount => 'createAccount',
  };

  static AuthEntryMode? fromStorage(String? value) {
    switch (value) {
      case 'signIn':
        return AuthEntryMode.signIn;
      case 'createAccount':
        return AuthEntryMode.createAccount;
      default:
        return null;
    }
  }
}

/// Loads the last successful auth entry mode, or Create account on first run.
Future<AuthEntryMode> loadPreferredAuthEntryMode() async {
  final prefs = await SharedPreferences.getInstance();
  return AuthEntryModeStorage.fromStorage(
        prefs.getString(authEntryModePreferenceKey),
      ) ??
      AuthEntryMode.createAccount;
}

Future<void> persistAuthEntryMode(AuthEntryMode mode) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setString(authEntryModePreferenceKey, mode.storageValue);
}
