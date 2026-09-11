import 'package:flutter_test/flutter_test.dart';
import 'package:serial/serial.dart';
import 'package:trycatch/ui/tiles/shared/time_series_chart.dart';

/// A single-packet transient (e.g. a large negative pyro spike in vertical
/// acceleration) must survive whole-flight decimation: first-sample bucketing
/// silently dropped it once a bucket held ~26 packets.
void main() {
  group('decimateExtremes', () {
    // Two series like the acceleration tile: signed vertical + magnitude.
    List<double Function(TelemetryFrame)> values() => [
          (f) => f.accelVertical,
          (f) => f.accelTotal,
        ];

    test('keeps a single-packet negative spike inside a crowded bucket', () {
      final frames = <TelemetryFrame>[];
      for (var i = 0; i < 26; i++) {
        frames.add(
          TelemetryFrame(
            receivedAtMs: i * 100,
            accelX: 0.3,
            accelY: -0.2,
            accelZ: i == 13 ? -157.0 : 9.8,
          ),
        );
      }
      // One bucket for the whole span, like a whole-flight window.
      final out = decimateExtremes(frames, (_) => 0, values());
      expect(out, contains(frames[13]));
      // Bounded: at most min+max per series.
      expect(out.length, lessThanOrEqualTo(4));
    });

    test('output stays time-ordered across buckets', () {
      final frames = [
        for (var i = 0; i < 40; i++)
          TelemetryFrame(
            receivedAtMs: i * 100,
            accelZ: 9.8 + (i % 7),
          ),
      ];
      final out = decimateExtremes(frames, (f) => f.receivedAtMs ~/ 1000, values());
      for (var i = 1; i < out.length; i++) {
        expect(
          out[i].receivedAtMs,
          greaterThanOrEqualTo(out[i - 1].receivedAtMs),
        );
      }
      expect(out, isNotEmpty);
    });

    test('empty input yields empty output', () {
      expect(decimateExtremes([], (_) => 0, values()), isEmpty);
    });
  });
}
