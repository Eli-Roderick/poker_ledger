class Player {
  final int? id;
  final String name;
  final String? email;
  final String? phone;
  final String? notes;
  final DateTime createdAt;
  final bool active;

  const Player({
    this.id,
    required this.name,
    this.email,
    this.phone,
    this.notes,
    required this.createdAt,
    this.active = true,
  });

  Player copyWith({
    int? id,
    String? name,
    String? email,
    String? phone,
    String? notes,
    DateTime? createdAt,
    bool? active,
  }) {
    return Player(
      id: id ?? this.id,
      name: name ?? this.name,
      email: email ?? this.email,
      phone: phone ?? this.phone,
      notes: notes ?? this.notes,
      createdAt: createdAt ?? this.createdAt,
      active: active ?? this.active,
    );
  }

  Map<String, Object?> toMap() => {
        'id': id,
        'name': name,
        'email': email,
        'phone': phone,
        'notes': notes,
        'created_at': createdAt.toIso8601String(),
        'active': active,
      };

  factory Player.fromMap(Map<String, Object?> map) => Player(
        id: map['id'] is int ? map['id'] as int : int.tryParse(map['id'].toString()),
        name: map['name'] as String,
        email: map['email'] as String?,
        phone: map['phone'] as String?,
        notes: map['notes'] as String?,
        createdAt: DateTime.parse(map['created_at'] as String),
        active: map['active'] as bool? ?? true,
      );
}
