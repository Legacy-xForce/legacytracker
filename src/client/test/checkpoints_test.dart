import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:legacytracker/src/data/models/checkpoint.dart';
import 'package:legacytracker/src/data/models/location_model.dart';
import 'package:legacytracker/src/data/network/checkpoint_service.dart';
import 'package:legacytracker/src/features/checkpoints/checkpoints_provider.dart';
import 'package:legacytracker/src/features/tracking/widgets/tracking_location_street_label.dart';
import 'package:provider/provider.dart';

Checkpoint cp(String id, double lat, double lon, int radius) => Checkpoint(
  id: id,
  name: id,
  latitude: lat,
  longitude: lon,
  radiusM: radius,
  createdBy: 'u1',
  canEdit: true,
);

void main() {
  group('resolveCheckpoint', () {
    test('nothing outside every circle', () {
      expect(resolveCheckpoint(45.01, 9, [cp('a', 45, 9, 100)]), isNull);
      expect(resolveCheckpoint(45, 9, const []), isNull);
    });

    test('inside a circle resolves to it', () {
      expect(resolveCheckpoint(45.0005, 9, [cp('a', 45, 9, 100)])?.id, 'a');
    });

    test('overlaps go to the smallest radius, then the nearest center', () {
      expect(
        resolveCheckpoint(45, 9, [cp('big', 45, 9, 250), cp('small', 45, 9, 50)])?.id,
        'small',
      );
      expect(
        resolveCheckpoint(45.0001, 9, [
          cp('far', 45.001, 9, 200),
          cp('near', 45, 9, 200),
        ])?.id,
        'near',
      );
    });
  });

  group('CheckpointService', () {
    CheckpointService serviceFor(int status, [String body = '{}']) =>
        CheckpointService(
          baseUrl: 'https://example.test',
          httpClient: MockClient((_) async => http.Response(body, status)),
        );

    test('a duplicate name is reported as nameTaken', () async {
      final service = serviceFor(409);
      await expectLater(
        service.create('t', name: 'Home', latitude: 1, longitude: 1, radiusM: 50),
        throwsA(isA<CheckpointException>().having((e) => e.nameTaken, 'nameTaken', true)),
      );
    });

    test('list parses checkpoints and can_edit', () async {
      final service = serviceFor(
        200,
        '{"checkpoints":[{"id":"a","name":"Home","latitude":1.5,"longitude":2.5,'
        '"radius_m":80,"created_by":"u1","can_edit":false}]}',
      );
      final list = await service.list('t');
      expect(list.single.name, 'Home');
      expect(list.single.radiusM, 80);
      expect(list.single.canEdit, isFalse);
    });
  });

  group('CheckpointsProvider map visibility', () {
    test('is shown by default and the choice is remembered', () async {
      SharedPreferences.setMockInitialValues({});
      final provider = CheckpointsProvider(
        service: CheckpointService(baseUrl: 'https://example.test'),
        prefs: SharedPreferences.getInstance(),
      );
      addTearDown(provider.dispose);
      expect(provider.showOnMap, isTrue);

      await provider.toggleShowOnMap();
      expect(provider.showOnMap, isFalse);
      expect((await SharedPreferences.getInstance()).getBool('checkpoints_on_map'),
          isFalse);

      final reopened = CheckpointsProvider(
        service: CheckpointService(baseUrl: 'https://example.test'),
        prefs: SharedPreferences.getInstance(),
      );
      addTearDown(reopened.dispose);
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(reopened.showOnMap, isFalse);
    });
  });

  group('LocationStreetLabel', () {
    testWidgets('shows the checkpoint name when inside one', (tester) async {
      final provider = CheckpointsProvider(
        service: CheckpointService(baseUrl: 'https://example.test'),
      );
      addTearDown(provider.dispose);
      provider.bindSession(userId: null, getAccessToken: () => null);
      provider.debugSetCheckpoints([cp('Office', 45, 9, 100)]);

      await tester.pumpWidget(
        ChangeNotifierProvider.value(
          value: provider,
          child: MaterialApp(
            home: Scaffold(
              body: LocationStreetLabel(
                location: LocationPoint(latitude: 45.0003, longitude: 9),
              ),
            ),
          ),
        ),
      );
      expect(find.text('Office'), findsOneWidget);
    });
  });
}
