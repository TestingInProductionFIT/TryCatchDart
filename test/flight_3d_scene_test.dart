import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:serial/serial.dart';
import 'package:trycatch/core/ring_buffer.dart';
import 'package:trycatch/core/dead_reckoning.dart';
import 'package:trycatch/core/geo.dart';
import 'package:trycatch/state/telemetry_store.dart';
import 'package:trycatch/ui/tiles/shared/flight_3d_common.dart';
import 'package:trycatch/ui/tiles/shared/rocket_mesh.dart';
import 'package:vector_math/vector_math_64.dart';

/// Locks the right-handed world frame (X east, Y up, Z south): a previous
/// revision used +Z north, a left-handed frame that rendered east/west
/// flipped on screen.
void main() {
  const lat0 = 50.0755;
  const lon0 = 14.4378;
  final cosLat0 = math.cos(lat0 * math.pi / 180);

  group('worldFromLatLon handedness', () {
    test('east is +X', () {
      final lon = lon0 + 100 / (metresPerDegreeLat * cosLat0);
      final p = worldFromLatLon(lat0, lon, 0, lat0, lon0, cosLat0);
      expect(p.x, closeTo(100, 1e-6));
      expect(p.z, closeTo(0, 1e-6));
    });

    test('north is -Z', () {
      final lat = lat0 + 100 / metresPerDegreeLat;
      final p = worldFromLatLon(lat, lon0, 0, lat0, lon0, cosLat0);
      expect(p.z, closeTo(-100, 1e-6));
      expect(p.x, closeTo(0, 1e-6));
    });

    test('south is +Z', () {
      final lat = lat0 - 50 / metresPerDegreeLat;
      final p = worldFromLatLon(lat, lon0, 0, lat0, lon0, cosLat0);
      expect(p.z, closeTo(50, 1e-6));
    });

    test('negative AGL clamps to the ground plane', () {
      final p = worldFromLatLon(lat0, lon0, -5, lat0, lon0, cosLat0);
      expect(p.y, 0);
    });
  });

  group('orientationMatrix compass', () {
    Vector3 noseOf(Matrix4 m) =>
        Vector3(m.getColumn(1).x, m.getColumn(1).y, m.getColumn(1).z);

    test('vertical rocket points up', () {
      final nose = noseOf(RocketMesh.orientationMatrix(
          pitchDeg: 0, yawDeg: 0, scale: 1));
      expect(nose.x, closeTo(0, 1e-9));
      expect(nose.y, closeTo(1, 1e-9));
      expect(nose.z, closeTo(0, 1e-9));
    });

    test('pitch toward north (yaw 0) tilts to -Z', () {
      final nose = noseOf(RocketMesh.orientationMatrix(
          pitchDeg: 90, yawDeg: 0, scale: 1));
      expect(nose.x, closeTo(0, 1e-9));
      expect(nose.y, closeTo(0, 1e-9));
      expect(nose.z, closeTo(-1, 1e-9));
    });

    test('pitch toward east (yaw 90) tilts to +X', () {
      final nose = noseOf(RocketMesh.orientationMatrix(
          pitchDeg: 90, yawDeg: 90, scale: 1));
      expect(nose.x, closeTo(1, 1e-9));
      expect(nose.y, closeTo(0, 1e-9));
      expect(nose.z, closeTo(0, 1e-9));
    });

    test('basis is a proper rotation (det +1, not a mirror)', () {
      final m = RocketMesh.orientationMatrix(
          pitchDeg: 30, yawDeg: 45, rollDeg: 10, scale: 2);
      expect(m.determinant(), closeTo(8.0, 1e-6));
    });
  });

  group('recovery display state', () {
    test('assembled states show the cone, popped states do not', () {
      for (final s in [
        FsmState.idle,
        FsmState.armed,
        FsmState.ascent,
        FsmState.debugLocked,
      ]) {
        expect(s.hasNosecone, isTrue, reason: '$s');
        expect(s.hasParachute, isFalse, reason: '$s');
        expect(s.showsParachute, isFalse, reason: '$s');
      }
      for (final s in [
        FsmState.apogee,
        FsmState.debugUnlocked,
        FsmState.unknown,
      ]) {
        expect(s.hasNosecone, isFalse, reason: '$s');
        expect(s.hasParachute, isFalse, reason: '$s');
        expect(s.showsParachute, isFalse, reason: '$s');
      }
      expect(FsmState.landed.hasNosecone, isFalse, reason: 'landed');
      expect(FsmState.landed.showsParachute, isFalse, reason: 'landed');
    });

    test('nose cone stays UNLOCKED after landing, canopy renders only mid-descent', () {
      expect(FsmState.parachute.hasNosecone, isFalse);
      expect(FsmState.parachute.hasParachute, isTrue);
      expect(FsmState.parachute.showsParachute, isTrue);
      expect(FsmState.landed.hasNosecone, isFalse);
      expect(FsmState.landed.hasParachute, isTrue);
      expect(FsmState.landed.showsParachute, isFalse);
    });

    test('scene airframe config follows the FSM state', () {
      TelemetryState stateWith(FsmState s) {
        final frame = TelemetryFrame(
          flags: FrameFlags.gpsFix | FrameFlags.gpsFix3d,
          latitude: 50.0,
          longitude: 14.0,
          gpsAltitude: 300,
          baroAltitude: 100,
          fsmStateId: s.id,
        );
        final history = RingBuffer<TelemetryFrame>(16)..push(frame);
        return TelemetryState(
          history: history,
          deadReckoningHistory: RingBuffer<DrPosition>(16),
          latest: frame,
        );
      }

      final chute = buildFlightScene(
          stateWith(FsmState.parachute), null)!;
      expect(chute.showParachute, isTrue);
      expect(chute.showNoseCone, isFalse);

      final landed =
          buildFlightScene(stateWith(FsmState.landed), null)!;
      expect(landed.showParachute, isFalse);
      expect(landed.showNoseCone, isFalse);

      final pad =
          buildFlightScene(stateWith(FsmState.armed), null)!;
      expect(pad.showNoseCone, isTrue);
      expect(pad.showParachute, isFalse);
    });
  });

  group('flightGroundGrid', () {
    FlightScene sceneWith({required double maxHoriz, required double maxAlt}) =>
        FlightScene(
          trail: const [],
          rocketPos: Vector3.zero(),
          rocketIsDr: false,
          maxAlt: maxAlt,
          maxHoriz: maxHoriz,
          pitchDeg: 0,
          yawDeg: 0,
          rollDeg: 0,
          showNoseCone: true,
          showParachute: false,
          siteName: null,
        );

    test('small flights keep the minimum context', () {
      final grid = flightGroundGrid(sceneWith(maxHoriz: 0, maxAlt: 0));
      expect(grid.half, greaterThanOrEqualTo(60.0));
    });

    test('huge flights cap at 20x20 km', () {
      final grid =
          flightGroundGrid(sceneWith(maxHoriz: 40000, maxAlt: 20000));
      expect(grid.half, lessThanOrEqualTo(10000.0));
    });
  });

  group('cgAnchorPos', () {
    // Display scale for the ~80 cm airframe (mesh spans 2.15 model units).
    const scale = 0.8 / 2.15;

    test('vertical on the pad lifts the CG so the tail clears the ground',
        () {
      final anchor = cgAnchorPos(
        rocketPos: Vector3.zero(),
        pitchDeg: 0,
        yawDeg: 0,
        scale: scale,
      );
      // Tail sits (cgY - finBottom) * scale below the CG.
      final expectLift =
          (RocketMesh.cgY - RocketMesh.finBottom) * scale;
      expect(anchor.x, closeTo(0, 1e-9));
      expect(anchor.z, closeTo(0, 1e-9));
      expect(anchor.y, closeTo(expectLift, 1e-9));
    });

    test('horizontal rests the belly at body radius', () {
      final anchor = cgAnchorPos(
        rocketPos: Vector3.zero(),
        pitchDeg: 90,
        yawDeg: 0,
        scale: scale,
      );
      expect(anchor.y, closeTo(RocketMesh.bodyRadius * scale, 1e-9));
    });

    test('aloft the reported position passes through untouched', () {
      final pos = Vector3(10, 100, -5);
      final anchor = cgAnchorPos(
        rocketPos: pos,
        pitchDeg: 30,
        yawDeg: 45,
        scale: scale,
      );
      expect(anchor.x, closeTo(pos.x, 1e-9));
      expect(anchor.y, closeTo(pos.y, 1e-9));
      expect(anchor.z, closeTo(pos.z, 1e-9));
    });

    test('CG sits between the fin bottoms and the nose tip', () {
      expect(RocketMesh.cgY, greaterThan(RocketMesh.finBottom));
      expect(RocketMesh.cgY, lessThan(RocketMesh.noseTip));
    });

    test('terrain surface lifts the airframe instead of the flat plane',
        () {
      const groundY = 12.0;
      final anchor = cgAnchorPos(
        rocketPos: Vector3(0, groundY, 0),
        pitchDeg: 0,
        yawDeg: 0,
        scale: scale,
        groundY: groundY,
      );
      final expectLift =
          (RocketMesh.cgY - RocketMesh.finBottom) * scale;
      expect(anchor.y, closeTo(groundY + expectLift, 1e-9));
    });

    test('mesh already above the terrain passes through untouched', () {
      const groundY = 12.0;
      final pos = Vector3(5, groundY + 50, -3);
      final anchor = cgAnchorPos(
        rocketPos: pos,
        pitchDeg: 0,
        yawDeg: 0,
        scale: scale,
        groundY: groundY,
      );
      expect(anchor.y, closeTo(pos.y, 1e-9));
    });
  });

  group('clampEyeAboveTerrain', () {
    FlightCamera camFor(Vector3 eye, Vector3 target) =>
        flightCameraFromEyeTarget(
          eye: eye,
          target: target,
          dist: eye.distanceTo(target),
          fovY: flightFovY,
          aspect: 800 / 600,
          lightDir: Vector3(0, 1, 0),
        );

    test('eye under the surface is lifted, target kept', () {
      final cam = camFor(Vector3(10, 3, 40), Vector3(0, 25, 0));
      final fixed = clampEyeAboveTerrain(cam, 30.0);
      expect(fixed.eye.y, closeTo(30.0, 1e-9));
      expect(fixed.eye.x, closeTo(10.0, 1e-9));
      expect(fixed.target, cam.target);
      expect(fixed.lightDir, cam.lightDir);
      // Still a working camera: the target projects on screen.
      expect(
          projectToScreen(
              Vector3(0, 25, 0), fixed.vp, const Size(800, 600)),
          isNotNull);
    });

    test('eye already above passes through untouched', () {
      final cam = camFor(Vector3(10, 50, 40), Vector3(0, 25, 0));
      expect(identical(clampEyeAboveTerrain(cam, 30.0), cam), isTrue);
    });
  });

  group('capTrailPoints', () {
    List<Vector3> pts(int n) => [
          for (var i = 0; i < n; i++) Vector3(i.toDouble(), 0, 0),
        ];

    test('short lists pass through untouched', () {
      final p = pts(10);
      expect(identical(capTrailPoints(p), p), isTrue);
    });

    test('tip exact, start kept, capped', () {
      final out = capTrailPoints(pts(1000));
      expect(out.length, lessThanOrEqualTo(400));
      expect(out.first.x, 0);
      expect(out.last.x, 999);
      for (var i = 1; i < out.length; i++) {
        expect(out[i].x, greaterThan(out[i - 1].x));
      }
    });

    test('deterministic for the same input', () {
      final a = capTrailPoints(pts(1234));
      final b = capTrailPoints(pts(1234));
      expect(a.length, b.length);
      for (var i = 0; i < a.length; i++) {
        expect(a[i].x, b[i].x);
      }
    });
  });

  group('trail bucket stability', () {
    TelemetryFrame fixAt(int ms, double alt) => TelemetryFrame(
          flags: FrameFlags.gpsFix | FrameFlags.gpsFix3d,
          latitude: 50.0,
          longitude: 14.0,
          gpsAltitude: 300,
          baroAltitude: alt,
          receivedAtMs: ms,
        );

    TelemetryState stateOf(List<TelemetryFrame> frames) {
      final history = RingBuffer<TelemetryFrame>(128);
      for (final f in frames) {
        history.push(f);
      }
      return TelemetryState(
        history: history,
        deadReckoningHistory: RingBuffer<DrPosition>(16),
        latest: frames.last,
      );
    }

    test('extending history does not move earlier trail points', () {
      List<TelemetryFrame> frames(int n) =>
          [for (var i = 0; i < n; i++) fixAt(i * 100, i.toDouble())];
      // 30 fixes at 10 Hz stay well under the cap in both scenes; the old
      // span-derived bucket resampled them differently as span grew.
      final a = buildFlightScene(stateOf(frames(30)), null)!;
      final b = buildFlightScene(stateOf(frames(60)), null)!;
      expect(a.trail.length, 30);
      expect(b.trail.length, greaterThanOrEqualTo(30));
      for (var i = 0; i < a.trail.length; i++) {
        expect(b.trail[i].x, closeTo(a.trail[i].x, 1e-9));
        expect(b.trail[i].y, closeTo(a.trail[i].y, 1e-9));
        expect(b.trail[i].z, closeTo(a.trail[i].z, 1e-9));
      }
    });
  });

  group('formatUnderMeters', () {
    test('one decimal under 10 m, whole metres above', () {
      expect(formatUnderMeters(0.26), '0.3 m under ground');
      expect(formatUnderMeters(3), '3.0 m under ground');
      expect(formatUnderMeters(25.6), '26 m under ground');
    });
  });

  group('near-plane clipping', () {
    Matrix4 vpFor(Vector3 eye, Vector3 target) {
      final proj = makePerspectiveMatrix(
          50 * math.pi / 180, 800 / 600, 0.1, 100000);
      return proj * makeViewMatrix(eye, target, Vector3(0, 1, 0));
    }

    const size = Size(800, 600);

    test('geometry just in front of the camera still projects', () {
      final eye = Vector3(0, 5, 10);
      final target = Vector3(0, 0, 0);
      final vp = vpFor(eye, target);
      final dir = (target - eye).normalized();
      // 20 cm in front of the lens: the old 0.5 m cutoff dropped this,
      // eating the rocket mesh and ground cells close to the camera.
      expect(projectToScreen(eye + dir * 0.2, vp, size), isNotNull);
    });

    test('geometry behind the camera is culled', () {
      final eye = Vector3(0, 5, 10);
      final target = Vector3(0, 0, 0);
      final vp = vpFor(eye, target);
      final dir = (target - eye).normalized();
      expect(projectToScreen(eye - dir * 1.0, vp, size), isNull);
    });
  });
}
