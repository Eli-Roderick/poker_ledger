import 'package:supabase_flutter/supabase_flutter.dart';

/// Converts Supabase auth errors to user-friendly messages
String formatAuthError(dynamic error) {
  String message = error.toString();
  
  // Handle AuthException specifically
  if (error is AuthException) {
    message = error.message;
  }
  
  // Clean up common prefixes
  message = message
      .replaceAll('Exception: ', '')
      .replaceAll('AuthException: ', '')
      .replaceAll('AuthApiException: ', '');
  
  // Map common Supabase error messages to friendly versions
  final lowerMessage = message.toLowerCase();
  
  if (lowerMessage.contains('invalid login credentials') ||
      lowerMessage.contains('invalid_credentials')) {
    return 'Incorrect email or password. Please try again.';
  }
  
  if (lowerMessage.contains('email not confirmed')) {
    return 'Please verify your email address before signing in. Check your inbox for a confirmation link.';
  }
  
  if (lowerMessage.contains('user not found') ||
      lowerMessage.contains('no user found')) {
    return 'No account found with this email. Would you like to sign up?';
  }
  
  if (lowerMessage.contains('too many requests') ||
      lowerMessage.contains('rate limit')) {
    return 'Too many attempts. Please wait a moment and try again.';
  }
  
  if (lowerMessage.contains('network') ||
      lowerMessage.contains('connection') ||
      lowerMessage.contains('socket') ||
      lowerMessage.contains('timeout')) {
    return 'Unable to connect. Please check your internet connection.';
  }
  
  if (lowerMessage.contains('email') && lowerMessage.contains('invalid')) {
    return 'Please enter a valid email address.';
  }
  
  if (lowerMessage.contains('password') && 
      (lowerMessage.contains('weak') || lowerMessage.contains('short'))) {
    return 'Password is too weak. Please use at least 6 characters.';
  }
  
  if (lowerMessage.contains('already registered') ||
      lowerMessage.contains('already exists') ||
      lowerMessage.contains('user already registered')) {
    return 'An account with this email already exists. Try signing in instead.';
  }
  
  if (lowerMessage.contains('signup is disabled')) {
    return 'New account registration is currently disabled.';
  }
  
  if (lowerMessage.contains('expired') || lowerMessage.contains('token')) {
    return 'Your session has expired. Please try again.';
  }
  
  // If we can't map it, return a cleaned-up version
  // Capitalize first letter and ensure it ends with a period
  if (message.isNotEmpty) {
    message = message[0].toUpperCase() + message.substring(1);
    if (!message.endsWith('.') && !message.endsWith('!') && !message.endsWith('?')) {
      message = '$message.';
    }
  }
  
  return message.isEmpty ? 'An unexpected error occurred. Please try again.' : message;
}
