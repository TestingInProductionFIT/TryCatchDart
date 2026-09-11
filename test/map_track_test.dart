import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:serial/serial.dart' show FrameFlags, TelemetryFrame;
import 'package:trycatch/core/dead_reckoning.dart';
import 'package:trycatch/core/ring_buffer.dart';
import 'package:trycatch/state/telemetry_store.dart';
import 'package:trycatch/ui/tiles/map_tile.dart'
    show drSegments, gpsTrackPoints;

TelemetryState _state({
  List<TelemetryFrame> frames = const [],
  List<DrPosition> dr = const [],
  bool replaying = false,
}) {
  final history = RingBuffer<TelemetryFrame>(9000);
  for (final f in frames) {
    history.push(f);
  }
  final drHistory = RingBuffer<DrPosition>(9000);
  for (final p in dr) {
    drHistory.push(p);
  }
  return TelemetryState(
    history: history,
    deadReckoningHistory: drHistory,
    replaying: replaying,
  );
}

TelemetryFrame _fix(int ms, double lat, double lon) => TelemetryFrame(
      receivedAtMs: ms,
      flags: FrameFlags.gpsFix,
      latitude: lat,
      longitude: lon,
    );

const _noFix = TelemetryFrame(flags: 0);

DrPosition _dr(int ms, double lat, double lon) => DrPosition(
      latitude: lat,
      longitude: lon,
      altitude: 0,
      atMs: ms,
    );

void main() {
  group('gpsTrackPoints', () {
    test('empty history yields no points', () {
      expect(gpsTrackPoints(_state()), isEmpty);
    });

    test('skips frames without a fix', () {
      final s = _state(frames: [_fix(1, 50.0, 14.0), _noFix, _fix(2, 50.1, 14.1)]);
      final pts = gpsTrackPoints(s);
      expect(pts, [const LatLng(50.0, 14.0), const LatLng(50.1, 14.1)]);
    });

    test('small tracks are kept whole', () {
      final s = _state(
        frames: [for (var i = 0; i < 100; i++) _fix(i, 50.0 + i * 0.001, 14.0)],
      );
      expect(gpsTrackPoints(s), hasLength(100));
    });

    test('full ring is decimated but keeps first and last fix', () {
      final s = _state(
        frames: [
          for (var i = 0; i < 9000; i++) _fix(i * 100, 50.0 + i * 0.0001, 14.0),
        ],
      );
      final pts = gpsTrackPoints(s);
      expect(pts.length, lessThanOrEqualTo(1500));
      expect(pts.first, const LatLng(50.0, 14.0));
      // Newest fix is always on the track even when off-stride.
      expect(pts.last.latitude, closeTo(50.0 + 8999 * 0.0001, 1e-9));
    });

    test('custom cap is honoured', () {
      final s = _state(
        frames: [for (var i = 0; i < 500; i++) _fix(i, 50.0, 14.0 + i * 0.001)],
      );
      final pts = gpsTrackPoints(s, maxPoints: 100);
      expect(pts.length, lessThanOrEqualTo(100));
      expect(pts.first, const LatLng(50.0, 14.0));
      expect(pts.last.longitude, closeTo(14.0 + 499 * 0.001, 1e-9));
    });
  });

  group('drSegments', () {
    test('empty DR history yields no segments', () {
      expect(drSegments(_state(frames: [_fix(1, 50.0, 14.0)])), isEmpty);
    });

    test('single gap is rooted at the last known fix', () {
      final s = _state(
        frames: [_fix(1000, 50.0, 14.0)],
        dr: [_dr(2000, 50.001, 14.0), _dr(3000, 50.002, 14.0)],
      );
      final segs = drSegments(s);
      expect(segs, hasLength(1));
      expect(
        segs.single,
        [
          const LatLng(50.0, 14.0),
          const LatLng(50.001, 14.0),
          const LatLng(50.002, 14.0),
        ],
      );
    });

    test('a >3 s jump splits the gap and re-roots at the newer fix', () {
      final s = _state(
        frames: [_fix(1000, 50.0, 14.0), _fix(9000, 51.0, 15.0)],
        dr: [
          _dr(2000, 50.001, 14.0),
          _dr(3000, 50.002, 14.0),
          // 7 s silence → new gap; fix at t=9000 anchors it.
          _dr(10000, 51.001, 15.0),
          _dr(11000, 51.002, 15.0),
        ],
      );
      final segs = drSegments(s);
      expect(segs, hasLength(2));
      expect(segs[0].first, const LatLng(50.0, 14.0));
      expect(
        segs[1],
        [
          const LatLng(51.0, 15.0),
          const LatLng(51.001, 15.0),
          const LatLng(51.002, 15.0),
        ],
      );
    });

    test('fixes after a DR point do not anchor its segment', () {
      final s = _state(
        frames: [_fix(1000, 50.0, 14.0), _fix(5000, 52.0, 16.0)],
        dr: [_dr(2000, 50.001, 14.0)],
      );
      final segs = drSegments(s);
      expect(segs, hasLength(1));
      // Anchor is the t=1000 fix, not the later one.
      expect(segs.single.first, const LatLng(50.0, 14.0));
    });

    test('single-point runs are dropped', () {
      // One DR point with no prior fix → anchor-less single point.
      final s = _state(dr: [_dr(2000, 50.001, 14.0)]);
      expect(drSegments(s), isEmpty);
    });
  });
}
