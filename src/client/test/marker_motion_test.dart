import 'package:flutter_test/flutter_test.dart';
import 'package:legacytracker/src/data/models/location_model.dart';
import 'package:legacytracker/src/features/tracking/widgets/tracking_map_tab.dart';

void main() {
  late DateTime now;
  late MarkerMotion motion;

  setUp(() {
    now = DateTime(2026, 1, 1, 12);
    MarkerMotion.clock = () => now;
  });

  tearDown(() {
    MarkerMotion.clock = DateTime.now;
  });

  testWidgets('glides to a fix that follows shortly after the last one', (
    tester,
  ) async {
    motion = MarkerMotion(vsync: tester, onTick: () {});
    motion.update(LocationPoint(latitude: 45, longitude: 9));
    now = now.add(const Duration(seconds: 2));
    motion.update(LocationPoint(latitude: 45.01, longitude: 9));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(motion.value!.latitude, inInclusiveRange(45.0, 45.01));
    expect(motion.value!.latitude, isNot(45.01));
    motion.dispose();
  });

  testWidgets('jumps to a fix that arrives after a long gap', (tester) async {
    motion = MarkerMotion(vsync: tester, onTick: () {});
    motion.update(LocationPoint(latitude: 45, longitude: 9));
    now = now.add(const Duration(seconds: 2));
    motion.update(LocationPoint(latitude: 45.001, longitude: 9));
    await tester.pump();
    await tester.pump(const Duration(seconds: 3));
    now = now.add(const Duration(minutes: 10));
    motion.update(LocationPoint(latitude: 46, longitude: 10));
    expect(motion.value!.latitude, 46);
    expect(motion.value!.longitude, 10);
    motion.dispose();
  });
}
