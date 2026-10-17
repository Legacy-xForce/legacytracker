/// A passkey registered on the user's account (as listed by the auth server).
class Passkey {
  const Passkey({
    required this.id,
    required this.name,
    required this.createdAt,
  });

  factory Passkey.fromJson(Map<String, dynamic> json) {
    return Passkey(
      id: json['id'] as String,
      name: json['deviceName'] as String? ?? 'Passkey',
      createdAt: DateTime.parse(json['createdAt'] as String),
    );
  }

  /// The credential ID (base64url).
  final String id;

  /// The provider that holds it ("Google Password Manager", "Samsung
  /// Pass"), or the server's generic name when the app couldn't tell.
  final String name;
  final DateTime createdAt;
}
