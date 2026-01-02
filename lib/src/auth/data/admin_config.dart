class AdminConfig {
  // Admin user IDs that can bypass maintenance mode
  static const List<String> adminUserIds = [
    '95749686-83df-4847-bce3-a8965f77b87c', // eli.roderick@gmail.com
  ];

  // Set to true to enable maintenance mode (blocks non-admin users)
  static const bool maintenanceMode = false;

  static bool isAdmin(String? userId) {
    if (userId == null) return false;
    return adminUserIds.contains(userId);
  }
}
