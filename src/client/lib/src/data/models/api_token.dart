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
    this.userId,
    this.userName,
    this.deleted = false,
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
      userId: json['user_id'] as String?,
      userName: json['user_name'] as String?,
      deleted: json['deleted'] == true,
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

  /// The owner's id and display name; set only by the everyone list.
  final String? userId;
  final String? userName;

  /// A deleted token no longer authenticates, but its activity stays readable.
  final bool deleted;
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

/// One request made with a token, as its activity page shows it.
class ApiTokenRequest {
  const ApiTokenRequest({
    required this.id,
    required this.method,
    required this.path,
    required this.statusCode,
    required this.createdAt,
    this.clientIp,
    this.userAgent,
    this.durationMs,
  });

  factory ApiTokenRequest.fromJson(Map<String, dynamic> json) {
    final id = json['id'];
    final status = json['status_code'];
    final createdAt = DateTime.tryParse(json['created_at'] as String? ?? '');
    if (id == null ||
        json['method'] is! String ||
        json['path'] is! String ||
        status is! int ||
        createdAt == null) {
      throw const FormatException('Invalid request entry');
    }
    return ApiTokenRequest(
      id: id.toString(),
      method: json['method'] as String,
      path: json['path'] as String,
      statusCode: status,
      createdAt: createdAt,
      clientIp: json['client_ip'] is String
          ? json['client_ip'] as String
          : null,
      userAgent: json['user_agent'] is String
          ? json['user_agent'] as String
          : null,
      durationMs: json['duration_ms'] is int
          ? json['duration_ms'] as int
          : null,
    );
  }

  final String id;
  final String method;
  final String path;
  final int statusCode;
  final DateTime createdAt;
  final String? clientIp;
  final String? userAgent;
  final int? durationMs;
}

/// A page of a token's request trail, newest first.
class ApiTokenRequestPage {
  const ApiTokenRequestPage({
    required this.requests,
    required this.hasMore,
    this.nextBefore,
  });

  final List<ApiTokenRequest> requests;
  final bool hasMore;

  /// Pass back as `before` to fetch the next page; null on the last one.
  final String? nextBefore;
}
