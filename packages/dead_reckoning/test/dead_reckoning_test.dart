import 'package:dead_reckoning/dead_reckoning.dart';
import 'package:test/test.dart';

DeadReckoningSample sample({
  required int tMs,
  double lat = 50,
  double lon = 14,
  double gpsAlt = 300,
  bool hasFix = true,
  double vN = 0,
  double vE = 0,
  double vDown = 0,
}) {
  return DeadReckoningSample(
    receivedAtMs: tMs,
    latitude: lat,
    longitude: lon,
    gpsAltitude: gpsAlt,
    hasFix: hasFix,
    velocityNorth: vN,
    velocityEast: vE,
    velocityDown: vDown,
  );
}

/// Local mask builders (were package helpers; now test-only so the
/// package exports just the weighted tuning objective).
List<DeadReckoningGapMask> syntheticDeadReckoningGaps(
  List<DeadReckoningSample> samples, {
  required int periodMs,
  required int maskMs,
}) {
  assert(periodMs > 0 && maskMs > 0);
  if (samples.isEmpty) return const [];
  final masks = <DeadReckoningGapMask>[];
  final start = samples.first.receivedAtMs;
  final end = samples.last.receivedAtMs;
  for (var cursor = start + periodMs;
      cursor + maskMs <= end;
      cursor += periodMs) {
    masks.add(
      DeadReckoningGapMask(startMs: cursor, endMs: cursor + maskMs),
    );
  }
  return masks;
}

List<DeadReckoningGapMask> detectDeadReckoningGaps(
  List<DeadReckoningSample> samples, {
  int minGapMs = 1000,
}) {
  final masks = <DeadReckoningGapMask>[];
  var runStart = -1;
  var lastFixMs = -1;
  for (var i = 0; i < samples.length; i++) {
    final sample = samples[i];
    if (sample.hasFix) {
      if (runStart >= 0) {
        if (sample.receivedAtMs - runStart >= minGapMs && lastFixMs >= 0) {
          masks.add(DeadReckoningGapMask(
            startMs: lastFixMs,
            endMs: sample.receivedAtMs,
          ));
        }
        runStart = -1;
      }
      lastFixMs = sample.receivedAtMs;
    } else if (runStart < 0) {
      runStart = sample.receivedAtMs;
    }
  }
  return masks;
}

void main() {
  group('DeadReckoningEstimator', () {
    test('returns null before the first GPS fix', () {
      final estimator = DeadReckoningEstimator();
      expect(estimator.update(sample(tMs: 0, hasFix: false)), isNull);
      expect(estimator.update(sample(tMs: 100, hasFix: false)), isNull);
    });

    test('position equals the fix right after anchoring', () {
      final estimator = DeadReckoningEstimator();
      final p = estimator.update(sample(tMs: 1000))!;
      expect(p.latitude, closeTo(50, 1e-12));
      expect(p.longitude, closeTo(14, 1e-12));
      expect(p.altitude, closeTo(300, 1e-9));
    });

    test('integrates velocity between fixes', () {
      final estimator = DeadReckoningEstimator();
      estimator.update(sample(tMs: 0)); // anchor at t=0

      // Fly north at 10 m/s for 10 seconds.
      for (var t = 1; t <= 10; t++) {
        estimator.update(sample(tMs: t * 1000, hasFix: false, vN: 10));
      }

      final p =
          estimator.update(sample(tMs: 11000, hasFix: false, vN: 10))!;
      // Trapezoidal rule: the first step ramps 0→10 (5 m), the rest add
      // 10 m each — 105 m total, exact for a ramp, no lag overshoot.
      expect(p.latitude, closeTo(50 + 105 / 111320, 1e-9));
      expect(p.longitude, closeTo(14, 1e-12));
      expect(estimator.distanceSinceAnchor, closeTo(105, 0.01));
    });

    test('re-anchors on each new fix, so drift does not accumulate', () {
      final estimator = DeadReckoningEstimator();
      estimator.update(sample(tMs: 0));

      // Drift 100 m north between fixes.
      for (var t = 1; t <= 10; t++) {
        estimator.update(sample(tMs: t * 1000, hasFix: false, vN: 10));
      }

      // New fix at a *different* place: position resets to it.
      final p = estimator.update(sample(tMs: 12000, lat: 50.001))!;
      expect(p.latitude, closeTo(50.001, 1e-12));
      expect(estimator.distanceSinceAnchor, closeTo(0, 1e-9));
    });

    test('no fix at all after reset', () {
      final estimator = DeadReckoningEstimator();
      estimator.update(sample(tMs: 0));
      estimator.reset();
      expect(estimator.position, isNull);
      expect(estimator.update(sample(tMs: 5000, hasFix: false)), isNull);
    });

    test('integrates vertical velocity (down positive)', () {
      final estimator = DeadReckoningEstimator();
      estimator.update(sample(tMs: 0));
      estimator.update(
          sample(tMs: 2000, hasFix: false, vDown: -5)); // 5 m/s up for 2 s
      final p =
          estimator.update(sample(tMs: 3000, hasFix: false, vDown: -5))!;
      // Trapezoidal: 0→5 ramp over 2 s (5 m) plus 5 m over the last
      // second — 10 m total.
      expect(p.altitude, closeTo(310, 0.01));
    });

    test('extrapolates beyond GPS loss for a bounded time', () {
      final estimator = DeadReckoningEstimator();
      estimator.update(sample(tMs: 0, lat: 50, lon: 14));

      // 5 s of 20 m/s eastward flight, then GPS dies but velocity stays.
      for (var t = 1; t <= 5; t++) {
        estimator.update(sample(tMs: t * 1000, hasFix: false, vE: 20));
      }
      for (var t = 6; t <= 15; t++) {
        estimator.update(sample(tMs: t * 1000, hasFix: false, vE: 20));
      }

      final p = estimator.position!;
      // Trapezoidal: the 0→20 step contributes half a step (10 m), then
      // 14 full steps — 290 m east.
      expect(haversineDistanceM(50, 14, p.latitude, p.longitude),
          closeTo(290, 1.5));
    });

    test('freezes at the touchdown floor instead of sliding', () {
      final estimator = DeadReckoningEstimator();
      estimator.update(sample(tMs: 0, lat: 50, lon: 14, gpsAlt: 300));

      // Descending at 6 m/s with wind drift: must pin at 298 m and stop.
      for (var t = 1; t <= 60; t++) {
        estimator.update(
            sample(tMs: t * 1000, hasFix: false, vDown: 6, vE: 3, vN: 1));
      }
      final landed = estimator.position!;
      expect(landed.altitude, closeTo(298, 0.01));

      // Keeps sliding nowhere: frozen horizontally too.
      for (var t = 61; t <= 120; t++) {
        estimator.update(
            sample(tMs: t * 1000, hasFix: false, vDown: 6, vE: 3, vN: 1));
      }
      final still = estimator.position!;
      expect(still.altitude, closeTo(298, 0.01));
      expect(still.latitude, closeTo(landed.latitude, 1e-12));
      expect(still.longitude, closeTo(landed.longitude, 1e-12));

      // A fresh airborne fix unfreezes.
      final up = estimator.update(sample(tMs: 121000, gpsAlt: 500))!;
      expect(up.altitude, closeTo(500, 0.01));
    });

    test('out-of-order sample never rewinds the clock', () {
      final estimator = DeadReckoningEstimator();
      estimator.update(sample(tMs: 0));
      estimator.update(sample(tMs: 1000, hasFix: false, vN: 10));
      estimator.update(sample(tMs: 2000, hasFix: false, vN: 10));
      // Late duplicate from t=1000: folds in without moving the clock back.
      estimator.update(sample(tMs: 1000, hasFix: false, vN: 10));
      final p =
          estimator.update(sample(tMs: 3000, hasFix: false, vN: 10))!;
      // Trapezoidal: 5 + 10 + 10 = 25 m north — identical to the
      // in-order stream.
      expect(p.latitude, closeTo(50 + 25 / 111320, 1e-9));
      expect(estimator.distanceSinceAnchor, closeTo(25, 0.01));
    });

    // ── Gravity correction ────────────────────────────────────────────────────

    test('gravity decelerates an ascending rocket during extrapolation', () {
      final estimator = DeadReckoningEstimator();
      // Anchor at 300 m, rocket ascending at 50 m/s (vDown = -50).
      estimator.update(sample(tMs: 0, gpsAlt: 300, vDown: -50));

      // Link dies — extrapolate for 6 s.
      // Naive (no gravity): 300 + 50*6 = 600 m.
      // With gravity: 300 + 50*6 − ½*9.81*36 ≈ 300 + 300 − 176.6 ≈ 423 m.
      final p = estimator.extrapolate(6000)!;
      expect(p.altitude, closeTo(300 + 50 * 6 - 0.5 * 9.80665 * 36, 0.5));
    });

    test('extrapolation returns rocket to ground after long link loss', () {
      final estimator = DeadReckoningEstimator();
      // Anchor at 300 m with upward velocity 50 m/s.
      estimator.update(sample(tMs: 0, gpsAlt: 300, vDown: -50));

      // Apogee ≈ 300 + 50²/(2*9.81) ≈ 428 m, then descends.
      // After t = 50/9.81 ≈ 5.1 s velocity is zero; by t=20 s rocket is far
      // below 298 m and should be clamped at the ground floor.
      estimator.extrapolate(20000);
      final p = estimator.position!;
      expect(p.altitude, closeTo(298, 0.01)); // clamped at ground floor
    });

    test('gravity integrated via 1-second ticks matches one large step', () {
      // Both approaches use the same exact-kinematics formula; they must agree
      // to within floating-point rounding over the non-grounded portion.
      // v0=50 m/s up, t=4 s: h = 300 + 50*4 − ½*9.81*16 ≈ 421.5 m (airborne).
      const g = 9.80665;
      const v0 = 50.0; // m/s up
      const dtS = 4.0; // s — short enough that h > 298 m (no ground clamp)

      final estimatorBig = DeadReckoningEstimator();
      estimatorBig.update(sample(tMs: 0, gpsAlt: 300, vDown: -v0));
      estimatorBig.extrapolate((dtS * 1000).toInt()); // one 4 s step

      final estimatorSmall = DeadReckoningEstimator();
      estimatorSmall.update(sample(tMs: 0, gpsAlt: 300, vDown: -v0));
      for (var t = 1; t <= dtS.toInt(); t++) {
        estimatorSmall.extrapolate(t * 1000); // four 1 s steps
      }

      // Exact analytic result: h = 300 + v0*t − ½g*t²
      final expected = 300 + v0 * dtS - 0.5 * g * dtS * dtS;
      // The one-step formula is exact; the 1-second path accumulates tiny
      // floating-point rounding over 4 steps — allow 0.5 m tolerance.
      expect(estimatorBig.position!.altitude, closeTo(expected, 0.01));
      expect(estimatorSmall.position!.altitude, closeTo(expected, 0.5));
    });

    // ── Terrain floor ─────────────────────────────────────────────────────────

    test('terrain floor overrides GPS-min heuristic when higher', () {
      final estimator = DeadReckoningEstimator();
      // GPS fix at 300 m → heuristic floor = 298 m.
      estimator.update(sample(tMs: 0, gpsAlt: 300));

      // Terrain query returns 310 m — higher than the heuristic.
      estimator.setTerrainFloor(310);
      expect(estimator.groundFloorMsl, closeTo(310, 1e-9));
      expect(estimator.hasRealTerrainFloor, isTrue);
    });

    test('GPS-min heuristic wins when terrain floor is lower', () {
      final estimator = DeadReckoningEstimator();
      // GPS fix at 300 m → heuristic floor = 298 m.
      estimator.update(sample(tMs: 0, gpsAlt: 300));

      // Terrain query returns 290 m (e.g. a nearby valley tile).
      estimator.setTerrainFloor(290);
      // max(290, 298) = 298 — the GPS-min heuristic still wins.
      expect(estimator.groundFloorMsl, closeTo(298, 1e-9));
    });

    test('rocket clamps at terrain floor when it is the effective floor',
        () {
      final estimator = DeadReckoningEstimator();
      estimator.update(sample(tMs: 0, gpsAlt: 300));
      estimator.setTerrainFloor(310); // terrain higher than heuristic

      // Descend past both floors — should pin at 310 m.
      for (var t = 1; t <= 30; t++) {
        estimator.update(sample(tMs: t * 1000, hasFix: false, vDown: 10));
      }
      expect(estimator.position!.altitude, closeTo(310, 0.01));
    });

    test('terrain floor cleared on reset, tune kept', () {
      final estimator = DeadReckoningEstimator(
        tune: const DeadReckoningTune(horizontalDrag: 0.1),
      );
      estimator.update(sample(tMs: 0, gpsAlt: 300, vDown: -40));
      estimator.setTerrainFloor(310);

      estimator.reset();
      expect(estimator.position, isNull);
      expect(estimator.groundFloorMsl, isNull);
      expect(estimator.hasRealTerrainFloor, isFalse);
      expect(estimator.tune.horizontalDrag, 0.1);
    });

    // ── Tune behaviour ────────────────────────────────────────────────────────

    test('horizontal drag shortens extrapolation', () {
      final plain = DeadReckoningEstimator();
      plain.update(sample(tMs: 0, gpsAlt: 500, vE: 20));
      plain.extrapolate(10000);

      final draggy = DeadReckoningEstimator(
        tune: const DeadReckoningTune(horizontalDrag: 0.5),
      );
      draggy.update(sample(tMs: 0, gpsAlt: 500, vE: 20));
      final p = draggy.extrapolate(10000)!;

      // No-drag: 200 m east. Drag 0.5/s: 20·(1−e⁻⁵)/0.5 ≈ 39.7 m.
      expect(
          haversineDistanceM(50, 14, plain.position!.latitude,
              plain.position!.longitude),
          closeTo(200, 1.5));
      expect(haversineDistanceM(50, 14, p.latitude, p.longitude),
          closeTo(20 * (1 - 0.0067379) / 0.5, 0.5));
    });

    test('velocity clamp scales spikes instead of following them', () {
      final estimator = DeadReckoningEstimator(
        tune: const DeadReckoningTune(maxHorizontalSpeed: 5),
      );
      estimator.update(sample(tMs: 0, gpsAlt: 500));
      estimator.update(sample(tMs: 1000, hasFix: false, vE: 20));
      final p = estimator.extrapolate(2000)!;
      // Live integration is raw (the clamp only steers extrapolation):
      // trapezoidal 0→20 over 1 s gives 10 m, plus the adopted 5 m/s
      // over the next second — 15 m total.
      expect(haversineDistanceM(50, 14, p.latitude, p.longitude),
          closeTo(15, 0.5));
    });

    test('extrapolation horizon holds the position and expires', () {
      final estimator = DeadReckoningEstimator(
        tune: const DeadReckoningTune(maxExtrapolationSeconds: 5),
      );
      estimator.update(sample(tMs: 0, gpsAlt: 500, vE: 20));
      final early = estimator.extrapolate(3000)!;
      expect(estimator.isExpired, isFalse);
      expect(
          haversineDistanceM(50, 14, early.latitude, early.longitude),
          closeTo(60, 1.0));

      final late = estimator.extrapolate(10000)!;
      expect(estimator.isExpired, isTrue);
      expect(late.latitude, closeTo(early.latitude, 1e-12));
      expect(late.longitude, closeTo(early.longitude, 1e-12));

      // A fresh fix clears the expiry.
      estimator.update(sample(tMs: 11000, lat: 50.001, gpsAlt: 500));
      expect(estimator.isExpired, isFalse);
    });
  });

  group('DeadReckoningTune', () {
    test('JSON round-trips', () {
      const tune = DeadReckoningTune(
        gravity: 9.81,
        horizontalDrag: 0.02,
        velocityFilterAlpha: 0.5,
        maxHorizontalSpeed: 80,
        maxVerticalSpeed: 120,
        groundToleranceM: 3,
        maxExtrapolationSeconds: 120,
      );
      expect(DeadReckoningTune.fromJson(tune.toJson()), tune);
      expect(
        DeadReckoningTune.fromJson(
            DeadReckoningTune.defaults.toJson()),
        DeadReckoningTune.defaults,
      );
    });

    test('compact string round-trips and rejects garbage', () {
      const tune = DeadReckoningTune(horizontalDrag: 0.03);
      final compact = tune.toCompactString();
      expect(compact.startsWith(deadReckoningTunePrefix), isTrue);
      expect(DeadReckoningTune.parseCompact(compact), tune);
      expect(DeadReckoningTune.parseCompact('nonsense'), isNull);
      expect(
          DeadReckoningTune.parseCompact('$deadReckoningTunePrefix!!!'),
          isNull);
    });
  });

  group('dead reckoning evaluation', () {
    List<DeadReckoningSample> straightFlight() {
      // 30 s climbing north at 10 m/s + 30 m/s up, fix every second. The
      // climb keeps the gravity-arc prediction airborne through masked gaps
      // (level flight would touch the ground floor mid-gap and freeze, by
      // design); horizontal motion is constant, so the horizontal error is
      // expected to vanish.
      return [
        for (var t = 0; t <= 30; t++)
          DeadReckoningSample(
            receivedAtMs: t * 1000,
            latitude: 50 + (10 * t) / 111320,
            longitude: 14,
            gpsAltitude: 500 + 30.0 * t,
            velocityNorth: 10,
            velocityDown: -30,
          ),
      ];
    }

    test('masked gap on a steady leg scores near-zero horizontal error',
        () {
      final samples = straightFlight();
      final evaluation = evaluateDeadReckoning(
        samples: samples,
        tune: DeadReckoningTune.defaults,
        masks: const [DeadReckoningGapMask(startMs: 10000, endMs: 15000)],
      );
      expect(evaluation.gaps, hasLength(1));
      expect(evaluation.gaps.single.scored, isTrue);
      expect(evaluation.weightedMeanHorizontalErrorM, closeTo(0, 1.0));
    });

    test('synthetic masks tile the flight', () {
      final samples = straightFlight();
      final masks = syntheticDeadReckoningGaps(
        samples,
        periodMs: 10000,
        maskMs: 3000,
      );
      // The t=0 window is skipped (it could never score for lack of an
      // anchor); the remaining two both score.
      expect(masks, hasLength(2));
      final evaluation = evaluateDeadReckoning(
        samples: samples,
        tune: DeadReckoningTune.defaults,
        masks: masks,
      );
      expect(evaluation.scored, hasLength(2));
      expect(evaluation.weightedMeanHorizontalErrorM, closeTo(0, 1.0));
      expect(evaluation.weightedVerticalRmseM, isNotNull);
    });

    test('real-gap detection finds outage spans', () {
      final samples = [
        sample(tMs: 0),
        sample(tMs: 1000, hasFix: false, vN: 10),
        sample(tMs: 2000, hasFix: false, vN: 10),
        sample(tMs: 3000),
        sample(tMs: 4000, hasFix: false),
        sample(tMs: 5000),
      ];
      final masks = detectDeadReckoningGaps(samples, minGapMs: 1500);
      expect(masks, hasLength(1));
      expect(masks.single.startMs, 0);
      expect(masks.single.endMs, 3000);
    });

    test('empty inputs score nothing', () {
      expect(
        evaluateDeadReckoning(
          samples: const [],
          tune: DeadReckoningTune.defaults,
          masks: const [DeadReckoningGapMask(startMs: 0, endMs: 1000)],
        ).gaps,
        isEmpty,
      );
    });
  });

  group('rotation-invariant evaluation', () {
    test('zero rotation returns identical samples', () {
      final samples = [
        sample(tMs: 0, lat: 50, lon: 14, vN: 3, vE: 4),
        sample(tMs: 1000, lat: 50.001, lon: 14.001, vN: 3, vE: 4),
      ];
      final rotated = rotatedDeadReckoningSamples(samples, 0);
      expect(rotated, hasLength(2));
      for (var i = 0; i < 2; i++) {
        expect(rotated[i].latitude, closeTo(samples[i].latitude, 1e-12));
        expect(rotated[i].longitude, closeTo(samples[i].longitude, 1e-12));
        expect(rotated[i].velocityNorth, closeTo(3, 1e-9));
        expect(rotated[i].velocityEast, closeTo(4, 1e-9));
        expect(rotated[i].hasFix, samples[i].hasFix);
      }
    });

    test('quarter turn maps a north leg onto an east leg', () {
      // One sample 100 m north of the origin, flying north at 10 m/s.
      final samples = [
        const DeadReckoningSample(receivedAtMs: 0, latitude: 50, longitude: 14),
        DeadReckoningSample(
          receivedAtMs: 1000,
          latitude: 50 + 100 / 111320,
          longitude: 14,
          velocityNorth: 10,
        ),
      ];
      final rotated =
          rotatedDeadReckoningSamples(samples, 3.141592653589793 / 2);
      // ~100 m east of the origin instead, flying east.
      expect(rotated[1].latitude, closeTo(50, 1e-6));
      expect(rotated[1].longitude, greaterThan(14));
      expect(
          haversineDistanceM(
              50, 14, rotated[1].latitude, rotated[1].longitude),
          closeTo(100, 0.5));
      expect(rotated[1].velocityNorth, closeTo(0, 1e-9));
      expect(rotated[1].velocityEast, closeTo(10, 1e-9));
    });

    test('full turn returns to the original track', () {
      final samples = [
        sample(tMs: 0, lat: 50, lon: 14, vN: 3, vE: 4),
        sample(tMs: 1000, lat: 50.001, lon: 14.002, vN: 3, vE: 4),
      ];
      final rotated = rotatedDeadReckoningSamples(
          samples, 2 * 3.141592653589793);
      expect(rotated[1].latitude, closeTo(50.001, 1e-9));
      expect(rotated[1].longitude, closeTo(14.002, 1e-9));
      expect(rotated[1].velocityNorth, closeTo(3, 1e-9));
      expect(rotated[1].velocityEast, closeTo(4, 1e-9));
    });

    test('steady leg scores near-zero on every heading', () {
      final samples = [
        for (var t = 0; t <= 30; t++)
          DeadReckoningSample(
            receivedAtMs: t * 1000,
            latitude: 50 + (10 * t) / 111320,
            longitude: 14,
            gpsAltitude: 500 + 30.0 * t,
            velocityNorth: 10,
            velocityDown: -30,
          ),
      ];
      final evaluation = evaluateDeadReckoningRotationInvariant(
        samples: samples,
        tune: DeadReckoningTune.defaults,
        masks: const [DeadReckoningGapMask(startMs: 10000, endMs: 15000)],
      );
      expect(evaluation.perRotation, hasLength(8));
      expect(evaluation.weightedMeanHorizontalErrorM, closeTo(0, 1.0));
    });

    test('single heading matches the plain evaluation', () {
      final samples = [
        for (var t = 0; t <= 30; t++)
          DeadReckoningSample(
            receivedAtMs: t * 1000,
            latitude: 50 + (10 * t) / 111320,
            longitude: 14,
            gpsAltitude: 500 + 30.0 * t,
            velocityNorth: 10,
            velocityDown: -30,
          ),
      ];
      const masks = [DeadReckoningGapMask(startMs: 10000, endMs: 15000)];
      final plain = evaluateDeadReckoning(
        samples: samples,
        tune: DeadReckoningTune.defaults,
        masks: masks,
      );
      final invariant = evaluateDeadReckoningRotationInvariant(
        samples: samples,
        tune: DeadReckoningTune.defaults,
        masks: masks,
        rotationCount: 1,
      );
      expect(invariant.weightedMeanHorizontalErrorM,
          closeTo(plain.weightedMeanHorizontalErrorM ?? -1, 1e-9));
    });
  });

  group('automatic optimization', () {
    // A leg that brakes hard: constant-velocity extrapolation overshoots,
    // so a draggy tune must win over defaults.
    List<DeadReckoningSample> brakingLeg() => [
          for (var t = 0; t <= 30; t++)
            DeadReckoningSample(
              receivedAtMs: t * 1000,
              latitude: 50 + (30 * t - 0.4 * t * t) / 111320,
              longitude: 14,
              gpsAltitude: 600 + 20.0 * t,
              velocityNorth: 30 - 0.8 * t,
              velocityDown: -20,
            ),
        ];

    test('finds drag on a braking leg and beats defaults', () async {
      final samples = brakingLeg();
      final masks = syntheticDeadReckoningGaps(
        samples,
        periodMs: 10000,
        maskMs: 5000,
      );
      expect(masks, isNotEmpty);
      // Acceleration tracking (on by default) already follows the braking
      // leg, so start from it disabled: then drag must win instead.
      const start =
          DeadReckoningTune(accelerationTracking: false);
      final plain = evaluateDeadReckoningRotationInvariant(
        samples: samples,
        tune: start,
        masks: masks,
        rotationCount: 4,
      );
      final result = await optimizeDeadReckoning(
        samples: samples,
        masks: masks,
        rotationCount: 4,
        start: start,
      );
      expect(result.completed, isTrue);
      expect(result.evaluationsRun, greaterThan(1));
      expect(result.tune.horizontalDrag, greaterThan(0));
      expect(
        result.evaluation.weightedMeanHorizontalErrorM!,
        lessThan(plain.weightedMeanHorizontalErrorM!),
      );
    });

    test('optimizer never regresses the braking leg', () async {
      final samples = brakingLeg();
      final masks = syntheticDeadReckoningGaps(
        samples,
        periodMs: 10000,
        maskMs: 5000,
      );
      final plain = evaluateDeadReckoningRotationInvariant(
        samples: samples,
        tune: DeadReckoningTune.defaults,
        masks: masks,
        rotationCount: 4,
      );
      final result = await optimizeDeadReckoning(
        samples: samples,
        masks: masks,
        rotationCount: 4,
      );
      // Whatever it finds (drag trims the residual here), the search
      // only adopts strict improvements.
      expect(
        result.evaluation.weightedMeanHorizontalErrorM!,
        lessThanOrEqualTo(plain.weightedMeanHorizontalErrorM! + 1e-9),
      );
    });

    test('finds the velocity scale on an under-reading leg', () async {
      // Positions advance at 10 m/s but the sensor reports 7 m/s: the
      // per-rocket scale (~1.43) must win over the default 1.0.
      final samples = [
        for (var t = 0; t <= 30; t++)
          DeadReckoningSample(
            receivedAtMs: t * 1000,
            latitude: 50 + (10 * t) / 111320,
            longitude: 14,
            gpsAltitude: 500 + 30.0 * t,
            velocityNorth: 7,
            velocityDown: -30,
          ),
      ];
      final masks = syntheticDeadReckoningGaps(
        samples,
        periodMs: 10000,
        maskMs: 5000,
      );
      final result = await optimizeDeadReckoning(
        samples: samples,
        masks: masks,
        rotationCount: 2,
      );
      expect(result.tune.velocityScale, closeTo(1.4, 0.05));
      final plain = evaluateDeadReckoningRotationInvariant(
        samples: samples,
        tune: DeadReckoningTune.defaults,
        masks: masks,
        rotationCount: 2,
      );
      expect(
        result.evaluation.weightedMeanHorizontalErrorM!,
        lessThan(plain.weightedMeanHorizontalErrorM!),
      );
    });

    test('leaves defaults alone on a steady leg', () async {
      final samples = [
        for (var t = 0; t <= 30; t++)
          DeadReckoningSample(
            receivedAtMs: t * 1000,
            latitude: 50 + (10 * t) / 111320,
            longitude: 14,
            gpsAltitude: 500 + 30.0 * t,
            velocityNorth: 10,
            velocityDown: -30,
          ),
      ];
      final masks = syntheticDeadReckoningGaps(
        samples,
        periodMs: 10000,
        maskMs: 3000,
      );
      final result = await optimizeDeadReckoning(
        samples: samples,
        masks: masks,
        rotationCount: 2,
      );
      // Ties keep the incumbent: a steady leg teaches nothing.
      expect(result.tune, DeadReckoningTune.defaults);
    });

    test('reports progress and honours cancel', () async {
      final samples = [
        for (var t = 0; t <= 30; t++)
          DeadReckoningSample(
            receivedAtMs: t * 1000,
            latitude: 50 + (10 * t) / 111320,
            longitude: 14,
            gpsAltitude: 500 + 30.0 * t,
            velocityNorth: 10,
            velocityDown: -30,
          ),
      ];
      final masks = syntheticDeadReckoningGaps(
        samples,
        periodMs: 10000,
        maskMs: 3000,
      );
      var reports = 0;
      final result = await optimizeDeadReckoning(
        samples: samples,
        masks: masks,
        rotationCount: 2,
        shouldCancel: () => reports >= 3,
        onProgress: (_) async => reports++,
      );
      expect(result.completed, isFalse);
      expect(reports, greaterThanOrEqualTo(3));
    });

    test('prediction track follows the masked window', () {
      final samples = [
        for (var t = 0; t <= 20; t++)
          DeadReckoningSample(
            receivedAtMs: t * 1000,
            latitude: 50 + (10 * t) / 111320,
            longitude: 14,
            gpsAltitude: 500 + 30.0 * t,
            velocityNorth: 10,
            velocityDown: -30,
          ),
      ];
      const masks = [DeadReckoningGapMask(startMs: 5000, endMs: 10000)];
      final predictions = predictDeadReckoningTrack(
        samples: samples,
        tune: DeadReckoningTune.defaults,
        masks: masks,
      );
      expect(predictions, hasLength(1));
      // One position per masked sample (t=5..9 s).
      expect(predictions.single.track, hasLength(5));
      // Ends where the endpoint evaluation predicts.
      final evaluation = evaluateDeadReckoning(
        samples: samples,
        tune: DeadReckoningTune.defaults,
        masks: masks,
      );
      // Ends one second before the endpoint evaluation (which projects
      // to the fix time): 10 m short along the steady leg.
      final last = predictions.single.track.last;
      final endpoint = evaluation.gaps.single.predicted!;
      expect(
        haversineDistanceM(last.latitude, last.longitude,
            endpoint.latitude, endpoint.longitude),
        closeTo(10, 0.5),
      );
    });
  });

  group('terrain shape and scenarios', () {
    DeadReckoningSample sample({
      required int tMs,
      double lat = 50,
      double lon = 14,
      double gpsAlt = 500,
      bool hasFix = true,
      double vN = 0,
      double vE = 0,
      double vDown = 0,
    }) {
      return DeadReckoningSample(
        receivedAtMs: tMs,
        latitude: lat,
        longitude: lon,
        gpsAltitude: gpsAlt,
        hasFix: hasFix,
        velocityNorth: vN,
        velocityEast: vE,
        velocityDown: vDown,
      );
    }

    test('floor follows the nearest terrain sample, not the valley', () {
      final estimator = DeadReckoningEstimator();
      estimator.update(sample(tMs: 0, gpsAlt: 400)); // pad, floor 398
      estimator.setTerrainSamples(const [
        // Valley tile at the pad (below the heuristic anyway).
        DeadReckoningTerrainSample(
            latitude: 50, longitude: 14, elevationMsl: 390),
        // Ridge 500 m north.
        DeadReckoningTerrainSample(
            latitude: 50 + 500 / 111320, longitude: 14, elevationMsl: 460),
      ]);

      // Climb out over the ridge, then sink back onto it: the estimate
      // pins at the 460 m ridge, not the 398 m valley floor.
      for (var t = 1; t <= 10; t++) {
        estimator.update(
            sample(tMs: t * 1000, hasFix: false, vN: 50, vDown: -20));
      }
      for (var t = 11; t <= 60; t++) {
        estimator.update(
            sample(tMs: t * 1000, hasFix: false, vDown: 5));
      }
      expect(estimator.position!.altitude, closeTo(460, 1.0));
    });

    test('no sample nearby falls back to the heuristic floor', () {
      final estimator = DeadReckoningEstimator();
      estimator.update(sample(tMs: 0, gpsAlt: 400));
      estimator.setTerrainSamples(const [
        // Far away: irrelevant.
        DeadReckoningTerrainSample(
            latitude: 60, longitude: 30, elevationMsl: 900),
      ]);
      for (var t = 1; t <= 30; t++) {
        estimator.update(
            sample(tMs: t * 1000, hasFix: false, vDown: 10));
      }
      expect(estimator.position!.altitude, closeTo(398, 0.5));
    });

    test('eval honours terrain through the whole replay', () {
      final samples = [
        sample(tMs: 0, gpsAlt: 500),
        for (var t = 1; t <= 10; t++)
          sample(tMs: t * 1000, hasFix: false, vDown: 30),
        sample(tMs: 11000, gpsAlt: 500),
      ];
      const masks = [DeadReckoningGapMask(startMs: 1000, endMs: 11000)];
      const terrain = [
        // Higher than the 498 m heuristic: the max() merge keeps it.
        DeadReckoningTerrainSample(
            latitude: 50, longitude: 14, elevationMsl: 510),
      ];
      final evaluation = evaluateDeadReckoning(
        samples: samples,
        tune: DeadReckoningTune.defaults,
        masks: masks,
        terrain: terrain,
      );
      // Without terrain the 300 m plunge clamps at 498; with the 510 m
      // ridge sample the endpoint prediction sits on the ridge instead.
      expect(evaluation.gaps.single.predicted!.altitude,
          closeTo(510, 1.0));
    });

    test('weighted objective scores a steady leg near zero', () {
      expect(deadReckoningGapWeight(
        const DeadReckoningGapMask(startMs: 0, endMs: 15000),
      ), closeTo(1, 1e-9));
      expect(deadReckoningGapWeight(
        const DeadReckoningGapMask(startMs: 0, endMs: 5000),
      ), closeTo(3, 1e-9));

      final samples = [
        // Anchor already at cruise (real anchors happen mid-flight; a
        // zero-velocity anchor would dip below the floor on the first
        // masked second and latch).
        sample(tMs: 0, gpsAlt: 500, vN: 10, vDown: -30),
        for (var t = 1; t <= 6; t++)
          sample(tMs: t * 1000, hasFix: false, vN: 10, vDown: -30),
        // Closing fix sits on the track itself (70 m north at 10 m/s).
        sample(tMs: 7000, lat: 50 + 70 / 111320, gpsAlt: 710),
      ];
      const masks = [
        DeadReckoningGapMask(startMs: 1000, endMs: 3000),
        DeadReckoningGapMask(startMs: 4000, endMs: 6000),
      ];
      final evaluation = evaluateDeadReckoning(
        samples: samples,
        tune: DeadReckoningTune.defaults,
        masks: masks,
      );
      expect(evaluation.scored, hasLength(2));
      expect(evaluation.weightedMeanHorizontalErrorM, lessThan(10));
    });
  });

  group('acceleration tracking', () {
    DeadReckoningSample accelSample({
      required int tMs,
      bool hasFix = true,
      double vN = 0,
    }) {
      return DeadReckoningSample(
        receivedAtMs: tMs,
        latitude: 50,
        longitude: 14,
        gpsAltitude: 2000,
        hasFix: hasFix,
        velocityNorth: vN,
      );
    }

    test('bends the projection along a braking leg', () {
      // Braking 3 m/s² from 30 m/s, sampled every 100 ms.
      DeadReckoningEstimator tracked() {
        final estimator = DeadReckoningEstimator();
        estimator.update(accelSample(tMs: 0, vN: 30));
        for (var t = 1; t <= 8; t++) {
          estimator.update(
              accelSample(tMs: t * 100, hasFix: false, vN: 30 - 0.3 * t));
        }
        return estimator;
      }

      // 3 s outage from t=800 ms: analytic Δ = 27.6·3 − ½·3·9 ≈ 69.3 m
      // on top of 22.9 m already integrated ≈ 92.2 m total; truth is
      // 30·3.8 − ½·3·3.8² ≈ 92.3 m. Constant-velocity overshoots to
      // ≈ 105.7 m instead.
      final trackedPos = tracked().extrapolate(3800)!;
      expect(
        haversineDistanceM(
            50, 14, trackedPos.latitude, trackedPos.longitude),
        closeTo(92.3, 2.0),
      );

      final frozen = DeadReckoningEstimator(
        tune: const DeadReckoningTune(accelerationTracking: false),
      );
      frozen.update(accelSample(tMs: 0, vN: 30));
      for (var t = 1; t <= 8; t++) {
        frozen.update(
            accelSample(tMs: t * 100, hasFix: false, vN: 30 - 0.3 * t));
      }
      final frozenPos = frozen.extrapolate(3800)!;
      expect(
        haversineDistanceM(
            50, 14, frozenPos.latitude, frozenPos.longitude),
        closeTo(105.7, 1.5),
      );
    });

    test('trust expires after the horizon budget', () {
      final estimator = DeadReckoningEstimator();
      estimator.update(accelSample(tMs: 0, vN: 30));
      for (var t = 1; t <= 8; t++) {
        estimator.update(
            accelSample(tMs: t * 100, hasFix: false, vN: 30 - 0.3 * t));
      }
      // 10 s outage: accel drives the first 4 s, then velocity holds.
      // Δ ≈ 27.6·10 − ½·3·16 = 276 − 24 = 252 m, plus 22.9 m live.
      final pos = estimator.extrapolate(10800)!;
      expect(
        haversineDistanceM(50, 14, pos.latitude, pos.longitude),
        closeTo(274.9, 3.0),
      );
    });

    test('steady flight is unaffected', () {
      final estimator = DeadReckoningEstimator();
      estimator.update(accelSample(tMs: 0, vN: 10));
      for (var t = 1; t <= 8; t++) {
        estimator.update(
            accelSample(tMs: t * 100, hasFix: false, vN: 10));
      }
      final pos = estimator.extrapolate(3800)!;
      expect(
        haversineDistanceM(50, 14, pos.latitude, pos.longitude),
        closeTo(38, 0.5),
      );
    });
  });

  group('terminal descent and vertical learning', () {
    // Steady 10 Hz descent leg with consistent altitude rate and reported
    // velocity: learning converges to scale ~1 and the outage holds the
    // terminal rate instead of plunging under gravity.
    void feedDescent(DeadReckoningEstimator estimator,
        {required double rateDown,
        required double reportedDown,
        required int seconds,
        int startMs = 0}) {
      // Pad fix first: grounds the touchdown floor where a real launch
      // would (the teleport span is rejected by the learning sign check).
      estimator.update(DeadReckoningSample(
        receivedAtMs: startMs - 100,
        latitude: 50,
        longitude: 14,
        gpsAltitude: 400,
        hasFix: true,
      ));
      final steps = seconds * 10;
      for (var i = 0; i <= steps; i++) {
        final t = startMs + i * 100;
        estimator.update(DeadReckoningSample(
          receivedAtMs: t,
          latitude: 50,
          longitude: 14,
          gpsAltitude: 900 - rateDown * (t - startMs) / 1000,
          velocityDown: reportedDown,
          hasFix: true,
        ));
      }
    }

    test('steady descent holds the terminal rate through an outage', () {
      final estimator = DeadReckoningEstimator();
      feedDescent(estimator, rateDown: 11, reportedDown: 11, seconds: 6);
      // Anchor ≈ 900 − 66 = 834 m; 10 s outage at 11 m/s → ≈ 724 m.
      final p = estimator.extrapolate(16000)!;
      expect(p.altitude, closeTo(724, 8));
      expect(p.regime, 'descent');
    });

    test('over-reading variometer is calibrated from altitude rates', () {
      // The reference flight's sensor reads ~3× high under canopy.
      final estimator = DeadReckoningEstimator();
      feedDescent(estimator, rateDown: 3, reportedDown: 10, seconds: 20);
      // Anchor ≈ 900 − 60 = 840 m; learned scale ≈ 0.3 → ≈ 30 m down.
      final p = estimator.extrapolate(30000)!;
      expect(p.altitude, greaterThan(790));
      expect(p.altitude, lessThan(840));
      expect(p.regime, 'descent');
    });

    test('unsteady spans teach no terminal regime', () {
      // Opening shock: altitude falls steadily but the reported speed
      // swings wildly. Nothing may be learned from it — the outage must
      // fall back to the ballistic arc (and the floor), never to a
      // garbage terminal rate.
      final estimator = DeadReckoningEstimator();
      estimator.update(const DeadReckoningSample(
        receivedAtMs: -100,
        latitude: 50,
        longitude: 14,
        gpsAltitude: 400,
        hasFix: true,
      ));
      for (var i = 0; i <= 60; i++) {
        final t = i * 100;
        estimator.update(DeadReckoningSample(
          receivedAtMs: t,
          latitude: 50,
          longitude: 14,
          gpsAltitude: 900 - 12.0 * t / 1000,
          velocityDown: i.isEven ? 10.0 : 30.0,
          hasFix: true,
        ));
      }
      // Pad anchor → floor ≈ 398 m. A learned 12 m/s terminal hold
      // would sit near 828 − 120 = 708 m; ballistic falls through to
      // the clamp instead.
      final p = estimator.extrapolate(16000)!;
      expect(p.altitude, closeTo(398, 2));
      expect(p.regime, 'landed');
    });

    test('apogee outage settles onto the terminal rate, not the floor', () {      // Fast thin-air descent with matching reports (apogee-like): learns
      // a terminal regime, then a 10 s total outage must hold descent
      // instead of gravity-plunging into the ground clamp.
      final estimator = DeadReckoningEstimator();
      feedDescent(estimator, rateDown: 10, reportedDown: 22, seconds: 4);
      final anchor = estimator.position!.altitude;
      final p = estimator.extrapolate(14000)!;
      expect(p.altitude, lessThan(anchor - 40));
      expect(p.altitude, greaterThan(anchor - 160));
      expect(p.regime, 'descent');
    });

    test('regime labels follow predicted motion', () {
      final estimator = DeadReckoningEstimator();
      estimator.update(sample(tMs: 0, gpsAlt: 500, vDown: -10));
      expect(estimator.position!.regime, 'climb');
      // Steady descent teaches the regime, then the label follows.
      feedDescent(estimator, rateDown: 5, reportedDown: 5, seconds: 4,
          startMs: 1000);
      expect(estimator.position!.regime, 'descent');
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
