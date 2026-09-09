import 'package:flutter_test/flutter_test.dart';
import 'package:serial/serial.dart';
import 'package:trycatch/src/estimation/dead_reckoning.dart';
import 'package:trycatch/src/geo/geo.dart';

TelemetryFrame frame({
  required int tMs,
  double lat = 50,
  double lon = 14,
  double gpsAlt = 300,
  bool gpsFix = true,
  double vN = 0,
  double vE = 0,
  double vDown = 0,
}) {
  return TelemetryFrame(
    receivedAtMs: tMs,
    flags: gpsFix ? FrameFlags.gpsFix : 0,
    latitude: lat,
    longitude: lon,
    gpsAltitude: gpsAlt,
    velocityNorth: vN,
    velocityEast: vE,
    velocityDown: vDown,
  );
}

void main() {
  group('DeadReckoningEstimator', () {
    test('returns null before the first GPS fix', () {
      final dr = DeadReckoningEstimator();
      expect(dr.update(frame(tMs: 0, gpsFix: false)), isNull);
      expect(dr.update(frame(tMs: 100, gpsFix: false)), isNull);
    });

    test('DR equals the fix right after anchoring', () {
      final dr = DeadReckoningEstimator();
      final p = dr.update(frame(tMs: 1000))!;
      expect(p.latitude, closeTo(50, 1e-12));
      expect(p.longitude, closeTo(14, 1e-12));
      expect(p.altitude, closeTo(300, 1e-9));
    });

    test('integrates velocity between fixes', () {
      final dr = DeadReckoningEstimator();
      dr.update(frame(tMs: 0)); // anchor at t=0

      // Fly north at 10 m/s for 10 seconds.
      for (var t = 1; t <= 10; t++) {
        dr.update(frame(tMs: t * 1000, gpsFix: false, vN: 10));
      }

      final p = dr.update(frame(tMs: 11000, gpsFix: false, vN: 10))!;
      expect(p.latitude, closeTo(50 + 110 / 111320, 1e-9));
      expect(p.longitude, closeTo(14, 1e-12));
      expect(dr.distanceSinceAnchor, closeTo(110, 0.01));
    });

    test('re-anchors on each new fix, so drift does not accumulate', () {
      final dr = DeadReckoningEstimator();
      dr.update(frame(tMs: 0));

      // Drift 100 m north between fixes.
      for (var t = 1; t <= 10; t++) {
        dr.update(frame(tMs: t * 1000, gpsFix: false, vN: 10));
      }

      // New fix at a *different* place: DR resets to it.
      final p = dr.update(frame(tMs: 12000, lat: 50.001))!;
      expect(p.latitude, closeTo(50.001, 1e-12));
      expect(dr.distanceSinceAnchor, closeTo(0, 1e-9));
    });

    test('no fix at all after reset', () {
      final dr = DeadReckoningEstimator();
      dr.update(frame(tMs: 0));
      dr.reset();
      expect(dr.position, isNull);
      expect(dr.update(frame(tMs: 5000, gpsFix: false)), isNull);
    });

    test('integrates vertical velocity (down positive)', () {
      final dr = DeadReckoningEstimator();
      dr.update(frame(tMs: 0));
      dr.update(frame(tMs: 2000, gpsFix: false, vDown: -5)); // 5 m/s up for 2 s
      final p = dr.update(frame(tMs: 3000, gpsFix: false, vDown: -5))!;
      expect(p.altitude, closeTo(315, 0.01));
    });

    test('extrapolates beyond GPS loss for a bounded time', () {
      final dr = DeadReckoningEstimator();
      dr.update(frame(tMs: 0, lat: 50, lon: 14));

      // 5 s of 20 m/s eastward flight, then GPS dies but velocity stays.
      for (var t = 1; t <= 5; t++) {
        dr.update(frame(tMs: t * 1000, gpsFix: false, vE: 20));
      }
      for (var t = 6; t <= 15; t++) {
        dr.update(frame(tMs: t * 1000, gpsFix: false, vE: 20));
      }

      final p = dr.position!;
      // 15 s * 20 m/s = 300 m east.
      expect(haversineDistanceM(50, 14, p.latitude, p.longitude),
          closeTo(300, 1.5));
    });

    test('freezes at the touchdown floor instead of sliding', () {
      final dr = DeadReckoningEstimator();
      dr.update(frame(tMs: 0, lat: 50, lon: 14, gpsAlt: 300));

      // Descending at 6 m/s with wind drift: must pin at 298 m and stop.
      for (var t = 1; t <= 60; t++) {
        dr.update(
            frame(tMs: t * 1000, gpsFix: false, vDown: 6, vE: 3, vN: 1));
      }
      final landed = dr.position!;
      expect(landed.altitude, closeTo(298, 0.01));

      // Keeps sliding nowhere: frozen horizontally too.
      for (var t = 61; t <= 120; t++) {
        dr.update(
            frame(tMs: t * 1000, gpsFix: false, vDown: 6, vE: 3, vN: 1));
      }
      final still = dr.position!;
      expect(still.altitude, closeTo(298, 0.01));
      expect(still.latitude, closeTo(landed.latitude, 1e-12));
      expect(still.longitude, closeTo(landed.longitude, 1e-12));

      // A fresh airborne fix unfreezes.
      final up = dr.update(frame(tMs: 121000, gpsAlt: 500))!;
      expect(up.altitude, closeTo(500, 0.01));
    });
  });

  group('geo', () {
    test('haversine matches known distance', () {
      // ~111.19 km per degree of latitude.
      final d = haversineDistanceM(50, 14, 51, 14);
      expect(d, closeTo(111190, 200));
    });

    test('offsetLatLon round-trips', () {
      final p = offsetLatLon(50.0755, 14.4378, northM: 500, eastM: -250);
      expect(p.latitude, greaterThan(50.0755));
      expect(p.longitude, lessThan(14.4378));
      expect(haversineDistanceM(50.0755, 14.4378, p.latitude, p.longitude),
          closeTo(559, 2));
    });
  });
}
