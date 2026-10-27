/// What a personal API token may do: `read` only reads, `write` can do
/// anything the user can.
enum ApiTokenScope {
  read,
  write;

  static ApiTokenScope? parse(Object? value) => switch (value) {
    'read' => ApiTokenScope.read,
    'write' => ApiTokenScope.write,
    _ => null,
  };
}

/// A personal API token as listed by the tracker: everything but the secret.
class ApiToken {
  const ApiToken({
    required this.id,
    required this.name,
    required this.scope,
    required this.hint,
    required this.createdAt,
    this.lastUsedAt,
    this.rotatedAt,
    this.allowedIps = const [],
  });

  factory ApiToken.fromJson(Map<String, dynamic> json) {
    final scope = ApiTokenScope.parse(json['scope']);
    if (scope == null) throw const FormatException('Unknown token scope');
    return ApiToken(
      id: json['id'] as String,
      name: json['name'] as String? ?? 'API token',
      scope: scope,
      hint: json['token_hint'] as String? ?? '',
      createdAt: DateTime.parse(json['created_at'] as String),
      lastUsedAt: _date(json['last_used_at']),
      rotatedAt: _date(json['rotated_at']),
      allowedIps: _addresses(json['allowed_ips']),
    );
  }

  static DateTime? _date(Object? value) =>
      value is String ? DateTime.tryParse(value) : null;

  static List<String> _addresses(Object? value) => value is List
      ? value.whereType<String>().toList(growable: false)
      : const [];

  final String id;
  final String name;
  final ApiTokenScope scope;

  /// Non-secret label, e.g. `legacy-tracker-01a1…1289`.
  final String hint;
  final DateTime createdAt;
  final DateTime? lastUsedAt;
  final DateTime? rotatedAt;

  /// Addresses or CIDR prefixes allowed to use it; empty means anywhere.
  final List<String> allowedIps;
}

/// A token as created or rotated: the only time its value is known.
class IssuedApiToken {
  const IssuedApiToken({required this.token, required this.value});

  factory IssuedApiToken.fromJson(Map<String, dynamic> json) {
    return IssuedApiToken(
      token: ApiToken.fromJson(json),
      value: json['token'] as String,
    );
  }

  final ApiToken token;

  /// The full `legacy-tracker-…` secret.
  final String value;
}
