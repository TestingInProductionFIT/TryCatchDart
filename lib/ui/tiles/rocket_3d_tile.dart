import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:vector_math/vector_math_64.dart';

import '../../state/telemetry_store.dart';
import '../components/waiting_for_data.dart';
import './shared/flight_3d_common.dart';
import './shared/orbit_camera.dart';
import './shared/rocket_mesh.dart';

/// 3D rocket orientation view.
///
/// A small software renderer built on `vector_math`: the parametric rocket
/// mesh is transformed by the rocket's attitude, lit with flat shading and
/// depth-sorted (painter's algorithm). Drag orbits the shared camera; a
/// corner compass shows the North / East / Up world axes with the same
/// colours as the flight-path view.
///
/// Attitude is rocket-oriented: pitch = tilt from vertical, yaw = heading,
/// roll = spin around the longitudinal axis.
class Rocket3dTile extends ConsumerStatefulWidget {
  const Rocket3dTile({super.key});

  @override
  ConsumerState<Rocket3dTile> createState() => _Rocket3dWidgetState();
}

class _Rocket3dWidgetState extends ConsumerState<Rocket3dTile> {
  @override
  Widget build(BuildContext context) {
    final latest = ref.watch(telemetryStoreProvider).latest;
    final camera = ref.watch(orbitCameraProvider);

    if (latest == null) {
      return Center(child: WaitingForData());
    }

    // Airframe configuration comes straight from the FSM state: the cone
    // pops at apogee and the canopy opens under parachute.
    final showNoseCone = latest.fsmState.hasNosecone;
    final showParachute = latest.fsmState.hasParachute;

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onPanUpdate: (details) =>
          ref.read(orbitCameraProvider.notifier).orbit(details.delta),
      child: CustomPaint(
        painter: _RocketPainter(
          pitchDeg: latest.pitch,
          yawDeg: latest.yaw,
          rollDeg: latest.roll,
          cameraAzimuthDeg: camera.azimuthDeg,
          cameraElevationDeg: camera.elevationDeg,
          showNoseCone: showNoseCone,
          showParachute: showParachute,
        ),
        child: const SizedBox.expand(),
      ),
    );
  }
}

// ── Renderer ─────────────────────────────────────────────────────────────────

/// Camera framing that centres the visible stack on screen.
///
/// The mesh origin sits below the geometric centre (nose tip at +1.38 vs
/// fin bottoms at −0.77), so looking at the origin parks the rocket high
/// with the tip clipped. The target midpoint follows the airframe
/// configuration — popped cone lowers it, the parachute raises it — and the
/// taller canopy stack gets a longer lens so nothing clips. [scale] must
/// match the model scale used by the painter.
({Vector3 target, double distance}) rocketFraming({
  required bool showNoseCone,
  required bool showParachute,
  double scale = 0.9,
}) {
  final top = showParachute
      ? RocketMesh.bodyTop + ParachuteMesh.apexY
      : showNoseCone
          ? RocketMesh.noseTip
          : RocketMesh.bodyTop;
  return (
    target: Vector3(0, (top + RocketMesh.finBottom) / 2 * scale, 0),
    distance: showParachute ? 3.6 : 3.2,
  );
}

class _RocketPainter extends CustomPainter {
  final double pitchDeg;
  final double yawDeg;
  final double rollDeg;
  final double cameraAzimuthDeg;
  final double cameraElevationDeg;
  final bool showNoseCone;
  final bool showParachute;

  _RocketPainter({
    required this.pitchDeg,
    required this.yawDeg,
    required this.rollDeg,
    required this.cameraAzimuthDeg,
    required this.cameraElevationDeg,
    this.showNoseCone = true,
    this.showParachute = false,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final aspect = size.width / math.max(1.0, size.height);
    final proj = makePerspectiveMatrix(radians(42), aspect, 0.1, 20.0);

    final azimuth = radians(cameraAzimuthDeg);
    final elevation = radians(cameraElevationDeg);
    final camDir = Vector3(
      math.cos(elevation) * math.sin(azimuth),
      math.sin(elevation),
      math.cos(elevation) * math.cos(azimuth),
    );
    // The camera looks at the middle of the visible stack (not the mesh
    // origin) so the rocket renders centred in every airframe state.
    const modelScale = 0.9;
    final framing = rocketFraming(
      showNoseCone: showNoseCone,
      showParachute: showParachute,
      scale: modelScale,
    );
    final target = framing.target;
    final view = makeViewMatrix(
      target + camDir.scaled(framing.distance), // eye
      target, // target
      Vector3(0, 1, 0), // up
    );
    final vp = proj * view;

    // Light: a headlight slightly above the camera so the visible side is lit.
    final light = (camDir.clone()..scale(0.6)) + Vector3(-0.25, 0.8, 0.1);

    // Shared mesh renderer + compass (same as the flight-path views).
    paintRocketMesh(
      canvas,
      size,
      vp,
      view,
      light.normalized(),
      rocketPos: Vector3.zero(),
      pitchDeg: pitchDeg,
      yawDeg: yawDeg,
      rollDeg: rollDeg,
      scale: modelScale,
      showNoseCone: showNoseCone,
      showParachute: showParachute,
    );
    paintCompass(canvas, size, view);
  }

  @override
  bool shouldRepaint(covariant _RocketPainter old) =>
      old.pitchDeg != pitchDeg ||
      old.yawDeg != yawDeg ||
      old.rollDeg != rollDeg ||
      old.cameraAzimuthDeg != cameraAzimuthDeg ||
      old.cameraElevationDeg != cameraElevationDeg ||
      old.showNoseCone != showNoseCone ||
      old.showParachute != showParachute;
}
