import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:legacytracker/src/features/tracking/widgets/marker_icons.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('a person marker is the web box, anchored on its centre', () async {
    final factory = MarkerIconFactory();
    addTearDown(factory.dispose);

    final image = await factory.personMarker(
      const MarkerPerson(id: 'user', name: 'Ada'),
    );

    expect(image.scale, 2.0);
    // PeerMarker.vue's 152x168 box at 2x.
    expect(image.width, 304);
    expect(image.height, 336);
    // The avatar sits in the middle, so it needs no anchor offset.
    expect(image.anchorOffsetY, 0);
    expectPng(image);
  });

  test('battery, motion and staleness each produce a different icon', () async {
    final factory = MarkerIconFactory();
    addTearDown(factory.dispose);

    const plain = MarkerPerson(id: 'a', name: 'Ada');
    final base = await factory.personMarker(plain);
    final battery = await factory.personMarker(
      const MarkerPerson(id: 'a', name: 'Ada', batteryLevel: 26),
    );
    final charging = await factory.personMarker(
      const MarkerPerson(
        id: 'a',
        name: 'Ada',
        batteryLevel: 26,
        isCharging: true,
      ),
    );
    final moving = await factory.personMarker(
      const MarkerPerson(
        id: 'a',
        name: 'Ada',
        batteryLevel: 26,
        isMoving: true,
        speedKmh: 34,
      ),
    );
    final stale = await factory.personMarker(
      const MarkerPerson(id: 'a', name: 'Ada', batteryLevel: 26, isStale: true),
    );

    final ids = {base.id, battery.id, charging.id, moving.id, stale.id};
    expect(ids, hasLength(5));
    for (final image in [battery, charging, moving, stale]) {
      expectPng(image);
    }
  });

  test(
    'selection is left to the annotation, not baked into the bitmap',
    () async {
      final factory = MarkerIconFactory();
      addTearDown(factory.dispose);

      final normal = await factory.personMarker(
        const MarkerPerson(id: 'a', name: 'Ada'),
      );
      final selected = await factory.personMarker(
        const MarkerPerson(id: 'a', name: 'Ada', isSelected: true),
      );

      // The map scales the icon (1.18 when selected), so the bitmap is shared.
      expect(selected.id, normal.id);
    },
  );

  test('a cluster grows horizontally with its faces', () async {
    final factory = MarkerIconFactory();
    addTearDown(factory.dispose);

    final cluster = await factory.clusterMarker(const [
      MarkerPerson(id: 'a', name: 'Ada'),
      MarkerPerson(id: 'b', name: 'Bo'),
      MarkerPerson(id: 'c', name: 'Cy'),
    ]);
    final overflow = await factory.clusterMarker(const [
      MarkerPerson(id: 'a', name: 'Ada'),
      MarkerPerson(id: 'b', name: 'Bo'),
      MarkerPerson(id: 'c', name: 'Cy'),
      MarkerPerson(id: 'd', name: 'Di'),
      MarkerPerson(id: 'e', name: 'Ed'),
    ]);

    // Max three faces plus one "+N" slot.
    expect(overflow.width, greaterThan(cluster.width));
    // ClusterMarker.vue: 52 bubble + 9 tail + 14 dot - 2, at 2x.
    expect(cluster.height, 146);
    // The tail dot sits 7 logical px above the image edge.
    expect(cluster.anchorOffsetY, closeTo(7, 1e-9));
    expectPng(cluster);
  });

  test('cluster face hit areas sit over the faces', () {
    // Two people: an 82 px bubble, faces centred 15 px either side of the
    // tail dot, and 40 px above it (face centre 26, dot centre 66).
    final two = MarkerIconFactory.clusterFaceOffsets(2);
    expect(two, hasLength(2));
    expect(two[0], const Offset(-15, -40));
    expect(two[1], const Offset(15, -40));

    // Three people: a 112 px bubble, faces centred at -30, 0 and 30.
    final three = MarkerIconFactory.clusterFaceOffsets(3);
    expect(three.map((o) => o.dx), orderedEquals(<double>[-30, 0, 30]));

    // Four people: 142 px wide, but the "+N" chip is not a person, so the
    // three faces keep centring themselves at -45, -15 and 15.
    final four = MarkerIconFactory.clusterFaceOffsets(4);
    expect(four, hasLength(3));
    expect(four.map((o) => o.dx), orderedEquals(<double>[-45, -15, 15]));
    expect(four.every((o) => o.dy == -40), isTrue);
  });

  test('the cluster face hit area is one transparent face square', () async {
    final factory = MarkerIconFactory();
    addTearDown(factory.dispose);

    final hit = await factory.clusterFaceHitArea();
    // 42 logical px, the ClusterMarker face size, at 2x.
    expect(hit.width, 84);
    expect(hit.height, 84);
    // Centred on its own coordinate offset, no bottom anchor.
    expect(hit.anchorOffsetY, 0);
    expectPng(hit);
    // One image serves every face of every bubble: cached.
    expect(identical(hit, await factory.clusterFaceHitArea()), isTrue);
  });

  test('a checkpoint label is a small dark pill sized to its name', () async {
    final factory = MarkerIconFactory();
    addTearDown(factory.dispose);

    final short = await factory.checkpointLabel(
      'Home',
      accent: markerAccentColor,
    );
    final long = await factory.checkpointLabel(
      'Casa Bullo, the long way round',
      accent: markerAccentColor,
    );

    expect(short.scale, 2.0);
    // 16 px line + 3 px padding each side, at 2x.
    expect(short.height, 44);
    expect(long.width, greaterThan(short.width));
    expectPng(short);
    expectPng(long);
  });

  test('event and beam icons render', () async {
    final factory = MarkerIconFactory();
    addTearDown(factory.dispose);

    final event = await factory.eventMarker(const Color(0xFF7C4DFF));
    final beam = await factory.headingBeam(markerAccentColor);

    for (final image in [event, beam]) {
      expectPng(image);
    }
  });
}

/// Mapbox's native addStyleImage decodes encoded image bytes on both
/// platforms, so every generated icon must be a PNG.
void expectPng(MarkerImage image) {
  expect(image.png.length, greaterThan(8));
  expect(image.png.sublist(0, 8), <int>[
    0x89,
    0x50,
    0x4E,
    0x47,
    0x0D,
    0x0A,
    0x1A,
    0x0A,
  ]);
}
