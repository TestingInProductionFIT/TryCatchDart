import 'package:flutter_test/flutter_test.dart';
import 'package:trycatch/src/telemetry/packet_rate_tracker.dart';

void main() {
  group('PacketRateTracker', () {
    late PacketRateTracker tracker;

    setUp(() {
      tracker = PacketRateTracker(
        windowDuration: const Duration(seconds: 2),
      );
    });

    test('initial state has zero rate and is timed out', () {
      expect(tracker.timeSinceLastPacket(), isNull);
      expect(tracker.isTimedOut(), isTrue);
      expect(tracker.getAveragePacketsPerSecond(), 0.0);
    });

    test('computes moving average rate correctly', () {
      tracker.sample(1000);

      for (var i = 0; i < 100; i++) {
        tracker.recordPacket(1000 + (i * 5));
      }

      tracker.sample(1500);

      final rate = tracker.getAveragePacketsPerSecond(1500);
      expect(rate, closeTo(200.0, 0.1));
    });

    test('naturally decays rate to 0 as inactivity reaches sliding window duration', () {
      tracker.sample(0);

      for (var i = 0; i < 100; i++) {
        tracker.recordPacket(i * 10);
      }
      tracker.sample(1000);

      expect(tracker.getAveragePacketsPerSecond(1000), closeTo(100.0, 0.1));
      expect(tracker.isTimedOut(1000), isFalse);

      tracker.sample(2000);
      expect(tracker.getAveragePacketsPerSecond(2000), closeTo(50.0, 0.1));
      expect(tracker.isTimedOut(2000), isFalse);

      tracker.sample(3000);
      expect(tracker.getAveragePacketsPerSecond(3000), 0.0);
      expect(tracker.isTimedOut(3000), isTrue);
    });

    test('reset clears counters and sample buffer', () {
      tracker.recordPacket(1000);
      tracker.sample(1000);
      tracker.reset();

      expect(tracker.getAveragePacketsPerSecond(), 0.0);
      expect(tracker.timeSinceLastPacket(), isNull);
    });
  });
}
