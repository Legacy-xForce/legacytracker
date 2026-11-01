import 'dart:async';
import 'dart:convert';
import 'dart:ui' as ui;

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
    ], style: ClusterStyle.light);
    final overflow = await factory.clusterMarker(const [
      MarkerPerson(id: 'a', name: 'Ada'),
      MarkerPerson(id: 'b', name: 'Bo'),
      MarkerPerson(id: 'c', name: 'Cy'),
      MarkerPerson(id: 'd', name: 'Di'),
      MarkerPerson(id: 'e', name: 'Ed'),
    ], style: ClusterStyle.light);

    // Max three faces plus one "+N" slot.
    expect(overflow.width, greaterThan(cluster.width));
    // ClusterMarker.vue: 46 bubble + 8 tail + 12 dot - 2, at 2x.
    expect(cluster.height, 128);
    // The tail dot sits 6 logical px above the image edge.
    expect(cluster.anchorOffsetY, closeTo(6, 1e-9));
    expectPng(cluster);
  });

  test('cluster face hit areas sit over the faces', () {
    // Two people: a 73 px bubble, faces centred 13.5 px either side of the
    // tail dot, and 35 px above it (face centre 23, dot centre 58).
    final two = MarkerIconFactory.clusterFaceOffsets(2);
    expect(two, hasLength(2));
    expect(two[0], const Offset(-13.5, -35));
    expect(two[1], const Offset(13.5, -35));

    // Three people: a 100 px bubble, faces centred at -27, 0 and 27.
    final three = MarkerIconFactory.clusterFaceOffsets(3);
    expect(three.map((o) => o.dx), orderedEquals(<double>[-27, 0, 27]));

    // Four people: 127 px wide, but the "+N" chip is not a person, so the
    // three faces keep centring themselves at -40.5, -13.5 and 13.5.
    final four = MarkerIconFactory.clusterFaceOffsets(4);
    expect(four, hasLength(3));
    expect(four.map((o) => o.dx), orderedEquals(<double>[-40.5, -13.5, 13.5]));
    expect(four.every((o) => o.dy == -35), isTrue);
  });

  test('the cluster face hit area is one transparent face square', () async {
    final factory = MarkerIconFactory();
    addTearDown(factory.dispose);

    final hit = await factory.clusterFaceHitArea();
    // 38 logical px, the ClusterMarker face size, at 2x.
    expect(hit.width, 76);
    expect(hit.height, 76);
    // Centred on its own coordinate offset, no bottom anchor.
    expect(hit.anchorOffsetY, 0);
    expectPng(hit);
    // One image serves every face of every bubble: cached.
    expect(identical(hit, await factory.clusterFaceHitArea()), isTrue);
  });

  test('the person hit area covers just the visible avatar', () async {
    final factory = MarkerIconFactory();
    addTearDown(factory.dispose);

    final hit = await factory.personHitArea();
    // 57 logical px - the ring the avatar shows - at 2x, not the 152x168
    // bitmap box the beam's footprint needs.
    expect(hit.width, 114);
    expect(hit.height, 114);
    expect(hit.anchorOffsetY, 0);
    expectPng(hit);
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

  group('animated pictures', () {
    // Two 2x2 frames, red then blue, 200 ms each.
    final gif = base64Decode(
      'R0lGODlhAgACAPAAAP8AAAAA/yH/C05FVFNDQVBFMi4wAwEAAAAh+QQAFAAAACwAAAAA'
      'AgACAAACAwQIFAAh+QQAFAAAACwAAAAAAgACAAACA0yYFAA7',
    );

    Future<void> loaded(MarkerIconFactory factory, MarkerPerson person) {
      final done = Completer<void>();
      void listener() {
        if (!done.isCompleted) done.complete();
      }

      factory.addListener(listener);
      // The first request starts the load; the marker is the initial until then.
      unawaited(factory.personMarker(person));
      return done.future.whenComplete(() => factory.removeListener(listener));
    }

    test('the map marker moves with the picture', () async {
      var now = DateTime(2026, 1, 1);
      final factory = MarkerIconFactory(clock: () => now);
      addTearDown(factory.dispose);
      final person = MarkerPerson(id: 'ada', name: 'Ada', avatarBytes: gif);

      expect(factory.avatarFrame(person), -1);
      expect(factory.hasAnimatedAvatars, isFalse);
      expect(factory.untilNextAvatarFrame, isNull);
      await loaded(factory, person);
      expect(factory.hasAnimatedAvatars, isTrue);
      expect(factory.untilNextAvatarFrame, const Duration(milliseconds: 200));

      expect(factory.avatarFrame(person), 0);
      final first = await factory.personMarker(person);
      now = now.add(const Duration(milliseconds: 250));
      expect(factory.avatarFrame(person), 1);
      final second = await factory.personMarker(person);
      // A frame is its own bitmap (so the map re-registers it) with other pixels.
      expect(second.id, isNot(first.id));
      expect(second.png, isNot(first.png));

      // ...and the loop comes round again to the first frame, already cached.
      now = now.add(const Duration(milliseconds: 150));
      expect(factory.avatarFrame(person), 0);
      expect((await factory.personMarker(person)).id, first.id);
    });

    test(
      'a still picture is one bitmap however long it is on screen',
      () async {
        var now = DateTime(2026, 1, 1);
        final factory = MarkerIconFactory(clock: () => now);
        addTearDown(factory.dispose);
        final still = (await factory.personMarker(
          const MarkerPerson(id: 'bob', name: 'Bob'),
        )).png;
        final person = MarkerPerson(id: 'bob', name: 'Bob', avatarBytes: still);

        await loaded(factory, person);
        expect(factory.hasAnimatedAvatars, isFalse);
        expect(factory.untilNextAvatarFrame, isNull);
        expect(factory.avatarFrame(person), -1);
        final first = await factory.personMarker(person);
        now = now.add(const Duration(seconds: 5));
        expect((await factory.personMarker(person)).id, first.id);
      },
    );

    test('the clock picks the frame, 10 ms delays play at 100 ms', () async {
      final start = DateTime(2026, 1, 1);
      Future<ui.Image> pixel() async {
        final recorder = ui.PictureRecorder();
        Canvas(recorder).drawRect(
          const Rect.fromLTWH(0, 0, 1, 1),
          Paint()..color = Colors.red,
        );
        return recorder.endRecording().toImage(1, 1);
      }

      final art = AvatarArt(
        [await pixel(), await pixel()],
        const [Duration(milliseconds: 10), Duration(milliseconds: 300)],
        start,
      );
      addTearDown(art.dispose);
      expect(art.frameAt(start), 0);
      expect(art.frameAt(start.add(const Duration(milliseconds: 99))), 0);
      expect(art.frameAt(start.add(const Duration(milliseconds: 100))), 1);
      expect(art.frameAt(start.add(const Duration(milliseconds: 399))), 1);
      expect(art.frameAt(start.add(const Duration(milliseconds: 400))), 0);
      // The caller sleeps exactly until the frame changes.
      expect(art.untilNextFrame(start), const Duration(milliseconds: 100));
      expect(
        art.untilNextFrame(start.add(const Duration(milliseconds: 250))),
        const Duration(milliseconds: 150),
      );
      expect(
        art.untilNextFrame(start.add(const Duration(milliseconds: 400))),
        const Duration(milliseconds: 100),
      );
    });
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
