/// A passkey registered on the user's account (as listed by the auth server).
class Passkey {
  const Passkey({
    required this.id,
    required this.name,
    required this.synced,
    required this.createdAt,
    this.lastUsedAt,
  });

  factory Passkey.fromJson(Map<String, dynamic> json) {
    return Passkey(
      id: json['id'] as String,
      name: json['name'] as String? ?? 'Passkey',
      synced: json['backed_up'] as bool? ?? false,
      createdAt: DateTime.parse(json['created_at'] as String),
      lastUsedAt: json['last_used_at'] == null
          ? null
          : DateTime.parse(json['last_used_at'] as String),
    );
  }

  final String id;

  /// The provider that holds it ("Google Password Manager", "iCloud
  /// Keychain"), unless the server was given another name.
  final String name;

  /// Backed up to the provider's cloud, so it follows the user to new phones.
  final bool synced;
  final DateTime createdAt;
  final DateTime? lastUsedAt;
}
