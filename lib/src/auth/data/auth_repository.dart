import 'package:supabase_flutter/supabase_flutter.dart';

/// Repository for authentication operations.
/// 
/// Handles sign up, sign in, sign out, password reset, and deleted account restoration.
class AuthRepository {
  final SupabaseClient _client = Supabase.instance.client;

  User? get currentUser => _client.auth.currentUser;
  
  Stream<AuthState> get authStateChanges => _client.auth.onAuthStateChange;

  /// Check if an email has a deleted account pending permanent deletion
  /// Uses a SECURITY DEFINER function to bypass RLS since user isn't authenticated yet
  Future<DeletedAccountInfo?> checkDeletedAccount(String email) async {
    final response = await _client.rpc(
      'check_deleted_account',
      params: {'check_email': email},
    );
    
    if (response == null || (response as List).isEmpty) return null;
    
    final data = response[0];
    return DeletedAccountInfo(
      userId: data['user_id'] as String,
      displayName: data['display_name'] as String?,
      deletedAt: DateTime.parse(data['deleted_at'] as String),
      deletionScheduledAt: DateTime.parse(data['deletion_scheduled_at'] as String),
    );
  }

  /// Restore a deleted account - requires correct password for security
  /// Returns true if restoration was successful
  Future<bool> restoreDeletedAccount(String email, String password) async {
    final response = await _client.rpc(
      'restore_deleted_account',
      params: {
        'restore_email': email,
        'restore_password': password,
      },
    );
    
    if (response == null) {
      throw Exception('Failed to restore account');
    }
    
    final result = response as Map<String, dynamic>;
    if (result['success'] != true) {
      throw Exception(result['error'] ?? 'Failed to restore account');
    }
    
    return true;
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
    // Try to sign in first - this validates the password
    try {
      return await _client.auth.signInWithPassword(
        email: email,
        password: password,
      );
    } catch (e) {
      // If sign in fails, check if it's because the account is deleted/banned
      // Only show restore option if password was correct (account is banned)
      if (e.toString().contains('banned') || e.toString().contains('Email not confirmed')) {
        final deletedAccount = await checkDeletedAccount(email);
        if (deletedAccount != null) {
          throw AccountDeletedException(
            'This account has been deleted and is scheduled for permanent removal in ${deletedAccount.daysRemaining} days.',
            deletedAccount,
          );
        }
      }
      // Re-throw the original error (wrong password, etc.)
      rethrow;
    }
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
