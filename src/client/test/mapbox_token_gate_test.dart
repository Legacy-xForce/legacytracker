import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:legacytracker/src/data/network/mapbox_token_gate.dart';
import 'package:legacytracker/src/data/network/mapbox_token_service.dart';

void main() {
  testWidgets('shows a retryable error when the token service fails', (
    tester,
  ) async {
    var refuse = true;
    final service = MapboxTokenService(
      baseUrl: 'https://tracker.test',
      getAccessToken: () => 'session',
      httpClient: MockClient((request) async {
        if (refuse) return http.Response('{"error":"unavailable"}', 503);
        return http.Response(
          jsonEncode({
            'token': 'tk.recovered',
            'expires_at': DateTime.now()
                .toUtc()
                .add(const Duration(hours: 1))
                .toIso8601String(),
          }),
          200,
        );
      }),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MapboxTokenGate(
            service: service,
            builder: (context, session) => Text('map ${session.token}'),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(find.text('Map unavailable'), findsOneWidget);

    refuse = false;
    await tester.tap(find.text('Retry'));
    await tester.pump();
    await tester.pump();

    expect(find.text('map tk.recovered'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    service.dispose();
  });

  testWidgets('uses the spike token when no service is configured', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MapboxTokenGate(
            devToken: 'pk.spike',
            builder: (context, session) => Text('map ${session.token}'),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('map pk.spike'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
  });
}
