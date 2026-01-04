import 'package:supabase_flutter/supabase_flutter.dart';

/// Repository for authentication operations.
/// 
/// Handles sign up, sign in, sign out, password reset, and deleted account restoration.
class AuthRepository {
  final SupabaseClient _client = Supabase.instance.client;

  User? get currentUser => _client.auth.currentUser;
  
  Stream<AuthState> get authStateChanges => _client.auth.onAuthStateChange;

  /// Check if an email has a deleted account pending permanent deletion
  Future<DeletedAccountInfo?> checkDeletedAccount(String email) async {
    final data = await _client
        .from('profiles')
        .select('id, display_name, deleted_at, deletion_scheduled_at')
        .eq('email', email)
        .not('deleted_at', 'is', null)
        .maybeSingle();
    
    if (data == null) return null;
    
    return DeletedAccountInfo(
      userId: data['id'] as String,
      displayName: data['display_name'] as String?,
      deletedAt: DateTime.parse(data['deleted_at'] as String),
      deletionScheduledAt: DateTime.parse(data['deletion_scheduled_at'] as String),
    );
  }

  /// Restore a deleted account by clearing the deletion flags
  Future<void> restoreDeletedAccount(String userId) async {
    await _client
        .from('profiles')
        .update({
          'deleted_at': null,
          'deletion_scheduled_at': null,
        })
        .eq('id', userId);
  }

  Future<AuthResponse> signUp({
    required String email,
    required String password,
    required String displayName,
    bool isPublic = false,
  }) async {
    final response = await _client.auth.signUp(
      email: email,
      password: password,
      data: {'display_name': displayName},
    );
    
    // Update the profile with privacy setting after signup
    if (response.user != null) {
      await _client
          .from('profiles')
          .update({'is_public': isPublic})
          .eq('id', response.user!.id);
    }
    
    return response;
  }

  Future<AuthResponse> signIn({
    required String email,
    required String password,
  }) async {
    // Check if account is deleted before allowing sign in
    final deletedAccount = await checkDeletedAccount(email);
    if (deletedAccount != null) {
      throw AccountDeletedException(
        'This account has been deleted and is scheduled for permanent removal in ${deletedAccount.daysRemaining} days.',
        deletedAccount,
      );
    }
    
    return await _client.auth.signInWithPassword(
      email: email,
      password: password,
    );
  }

  Future<void> signOut() async {
    await _client.auth.signOut();
  }

  Future<void> resetPassword(String email) async {
    await _client.auth.resetPasswordForEmail(
      email,
      redirectTo: 'https://eli-roderick.github.io/poker_ledger/',
    );
  }
}

/// Information about a deleted account pending permanent deletion
class DeletedAccountInfo {
  final String userId;
  final String? displayName;
  final DateTime deletedAt;
  final DateTime deletionScheduledAt;
  
  const DeletedAccountInfo({
    required this.userId,
    this.displayName,
    required this.deletedAt,
    required this.deletionScheduledAt,
  });
  
  /// Days remaining before permanent deletion
  int get daysRemaining {
    final now = DateTime.now();
    return deletionScheduledAt.difference(now).inDays;
  }
}

/// Exception thrown when trying to sign in to a deleted account
class AccountDeletedException implements Exception {
  final String message;
  final DeletedAccountInfo accountInfo;
  
  const AccountDeletedException(this.message, this.accountInfo);
  
  @override
  String toString() => message;
}
