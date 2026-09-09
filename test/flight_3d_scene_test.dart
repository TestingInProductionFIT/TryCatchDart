import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:serial/serial.dart';
import 'package:trycatch/src/collections/ring_buffer.dart';
import 'package:trycatch/src/estimation/dead_reckoning.dart';
import 'package:trycatch/src/geo/geo.dart';
import 'package:trycatch/src/telemetry/telemetry_store.dart';
import 'package:trycatch/workspaces/widgets/flight_3d_common.dart';
import 'package:trycatch/workspaces/widgets/rocket_mesh.dart';
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
      }
      for (final s in [
        FsmState.apogee,
        FsmState.landed,
        FsmState.debugUnlocked,
        FsmState.unknown,
      ]) {
        expect(s.hasNosecone, isFalse, reason: '$s');
        expect(s.hasParachute, isFalse, reason: '$s');
      }
    });

    test('only the parachute state opens the canopy', () {
      expect(FsmState.parachute.hasNosecone, isFalse);
      expect(FsmState.parachute.hasParachute, isTrue);
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

      final pad =
          buildFlightScene(stateWith(FsmState.armed), null)!;
      expect(pad.showNoseCone, isTrue);
      expect(pad.showParachute, isFalse);
    });
  });
}
