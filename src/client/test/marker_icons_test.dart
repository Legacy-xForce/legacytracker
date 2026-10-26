import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:legacytracker/src/features/tracking/widgets/marker_icons.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('live marker renders a 2x bitmap anchored on its tail dot', () async {
    final factory = MarkerIconFactory();
    addTearDown(factory.dispose);

    final image = await factory.liveMarker(const [
      MarkerPerson(id: 'user', name: 'Ada'),
    ]);

    expect(image.scale, 2.0);
    expect(image.width, greaterThan(0));
    expect(image.height, greaterThan(image.width));
    expect(image.rgba.length, image.width * image.height * 4);
    // The dot sits 7 logical px above the image edge.
    expect(image.anchorOffsetY, closeTo(7, 1e-9));
  });

  test('a cluster grows horizontally with its faces', () async {
    final factory = MarkerIconFactory();
    addTearDown(factory.dispose);

    final single = await factory.liveMarker(const [
      MarkerPerson(id: 'a', name: 'Ada'),
    ]);
    final cluster = await factory.liveMarker(const [
      MarkerPerson(id: 'a', name: 'Ada'),
      MarkerPerson(id: 'b', name: 'Bo'),
      MarkerPerson(id: 'c', name: 'Cy'),
    ]);
    final overflow = await factory.liveMarker(const [
      MarkerPerson(id: 'a', name: 'Ada'),
      MarkerPerson(id: 'b', name: 'Bo'),
      MarkerPerson(id: 'c', name: 'Cy'),
      MarkerPerson(id: 'd', name: 'Di'),
      MarkerPerson(id: 'e', name: 'Ed'),
    ]);

    expect(cluster.width, greaterThan(single.width));
    // Max three faces plus one "+N" slot.
    expect(overflow.width, greaterThan(cluster.width));
  });

  test('selection and staleness produce different icons', () async {
    final factory = MarkerIconFactory();
    addTearDown(factory.dispose);

    final normal = await factory.liveMarker(const [
      MarkerPerson(id: 'a', name: 'Ada'),
    ]);
    final selected = await factory.liveMarker(const [
      MarkerPerson(id: 'a', name: 'Ada', isSelected: true),
    ]);
    final stale = await factory.liveMarker(const [
      MarkerPerson(id: 'a', name: 'Ada', isStale: true),
    ]);

    expect(selected.id, isNot(normal.id));
    expect(stale.id, isNot(normal.id));
  });

  test('replay, event and beam icons render', () async {
    final factory = MarkerIconFactory();
    addTearDown(factory.dispose);

    final replay = await factory.replayMarker(
      person: const MarkerPerson(id: 'a', name: 'Ada'),
      speedKmh: 34,
      isMoving: true,
    );
    final event = await factory.eventMarker(const Color(0xFF7C4DFF));
    final beam = await factory.headingBeam(markerAccentColor);

    for (final image in [replay, event, beam]) {
      expect(image.rgba.length, image.width * image.height * 4);
    }
  });
}
