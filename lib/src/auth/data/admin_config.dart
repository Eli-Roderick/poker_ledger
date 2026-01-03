class AdminConfig {
  // Admin user IDs that can bypass maintenance mode
  static const List<String> adminUserIds = [
    '95749686-83df-4847-bce3-a8965f77b87c', // eli.roderick@gmail.com
    'ab2da640-4831-43ef-be62-059553dcf5c0',
    '89a6ed48-238d-4999-bb93-0406276fdf97',
    '369d866d-6af9-4961-b8fb-29805423ca69',
  ];

  // Set to true to enable maintenance mode (blocks non-admin users)
  static const bool maintenanceMode = true;

  static bool isAdmin(String? userId) {
    if (userId == null) return false;
    return adminUserIds.contains(userId);
  }
}
