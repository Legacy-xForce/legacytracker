import 'dart:convert';

import 'package:http/http.dart' as http;

/// What every network failure reads as, so the same sentence never drifts.
const String kUnreachableMessage =
    'Unable to reach the server. Check your connection and try again.';

/// A request that failed, with a message safe to show to the user. [status]
/// is the HTTP status when the server answered, null when it was unreachable.
class ApiException implements Exception {
  ApiException(this.message, {this.status});

  final String message;
  final int? status;

  @override
  String toString() => message;
}

/// The plumbing the API services share: base URI, one [http.Client], the
/// timeout, the auth headers and reading the server's error text.
class ApiClient {
  ApiClient({
    required String baseUrl,
    http.Client? httpClient,
    this.timeout = const Duration(seconds: 15),
  }) : baseUri = Uri.parse(baseUrl),
       httpClient = httpClient ?? http.Client();

  final Uri baseUri;
  final http.Client httpClient;
  final Duration timeout;

  Uri uri(String path, {Map<String, String>? queryParameters}) =>
      baseUri.replace(path: path, queryParameters: queryParameters);

  /// Only requests with a body name a JSON type: the server answers 400 to an
  /// empty body that claims to be JSON.
  Map<String, String> headers(String accessToken, {bool json = false}) => {
    if (json) 'content-type': 'application/json',
    'authorization': 'Bearer $accessToken',
  };

  /// Runs [request] with the timeout; any transport failure becomes an
  /// [ApiException] with [kUnreachableMessage].
  Future<http.Response> send(Future<http.Response> Function() request) async {
    try {
      return await request().timeout(timeout);
    } on Exception {
      throw ApiException(kUnreachableMessage);
    }
  }

  /// The JSON object in [response], decoded as UTF-8 whatever charset it names.
  static Map<String, dynamic> json(http.Response response) =>
      jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;

  /// The server's `error` text, or null when the body is not JSON.
  static String? serverMessage(http.Response response) {
    try {
      return json(response)['error'] as String?;
    } catch (_) {
      return null;
    }
  }

  void close() => httpClient.close();
}
