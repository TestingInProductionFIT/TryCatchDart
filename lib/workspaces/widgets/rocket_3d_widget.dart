import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:vector_math/vector_math_64.dart';

import '../../src/telemetry/telemetry_store.dart';
import '../../theme/app_colors.dart';
import '../../theme/widgets/waiting_for_data.dart';
import 'orbit_camera.dart';
import 'rocket_mesh.dart';

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
class Rocket3dWidget extends ConsumerStatefulWidget {
  const Rocket3dWidget({super.key});

  @override
  ConsumerState<Rocket3dWidget> createState() => _Rocket3dWidgetState();
}

class _Rocket3dWidgetState extends ConsumerState<Rocket3dWidget> {
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
    // With the chute out the stack is taller: look slightly up so the
    // canopy fits. The rocket itself keeps its scale — only the camera
    // target moves.
    final target = showParachute ? Vector3(0, 0.45, 0) : Vector3.zero();
    final view = makeViewMatrix(
      target + camDir.scaled(3.2), // eye
      target, // target
      Vector3(0, 1, 0), // up
    );
    final vp = proj * view;

    // ── Model matrix: roll about the long axis, then orient the nose ────────
    final model = RocketMesh.orientationMatrix(
      pitchDeg: pitchDeg,
      yawDeg: yawDeg,
      rollDeg: rollDeg,
      scale: 0.9,
    );

    // Light: a headlight slightly above the camera so the visible side is lit.
    final light = (camDir.clone()..scale(0.6)) + Vector3(-0.25, 0.8, 0.1);
    final lightDir = light.normalized();

    _paintMesh(canvas, size, vp, view, model, lightDir,
        showNoseCone: showNoseCone, showParachute: showParachute);
    _paintAxisGizmo(canvas, size, view);
  }

  void _paintMesh(
    Canvas canvas,
    Size size,
    Matrix4 vp,
    Matrix4 view,
    Matrix4 model,
    Vector3 lightDir, {
    required bool showNoseCone,
    required bool showParachute,
  }) {
    // Transform all mesh triangles; painter's algorithm by view depth.
    // The sort is stabilised by mesh order and degenerate (zero-area)
    // projections are skipped: coplanar double-sided fin faces otherwise
    // flicker as Dart's sort leaves equal-depth order undefined.
    final visible = <_Tri>[];
    var index = 0;

    // Parachute frame: translated to the body-top attach point, uniformly
    // scaled, but never rotated — the canopy always hangs straight up.
    final chuteModel = Matrix4.translation(
            model.transformed3(Vector3(0, RocketMesh.bodyTop, 0)))
        ..scaleByDouble(0.9, 0.9, 0.9, 1.0);

    void push(RocketMeshTri tri, Matrix4 m, Vector3 worldNormal) {
      final a = m.transformed3(tri.a);
      final b = m.transformed3(tri.b);
      final c = m.transformed3(tri.c);

      final screenA = _toScreen(a, vp, size);
      final screenB = _toScreen(b, vp, size);
      final screenC = _toScreen(c, vp, size);
      if (screenA == null || screenB == null || screenC == null) return;
      final area = (screenB.dx - screenA.dx) * (screenC.dy - screenA.dy) -
          (screenC.dx - screenA.dx) * (screenB.dy - screenA.dy);
      if (area.abs() < 1e-6) return;

      // Closed airframe: cull backfaces so the far wall can never bleed
      // through the near one at glancing angles (the old streaks). Fin
      // sheets come in exact opposite pairs, so exactly one survives.
      // Parachute sheets (noCull) always draw, from both sides.
      if (!tri.noCull) {
        final viewNormal = view.transformed(Vector4(
            worldNormal.x, worldNormal.y, worldNormal.z, 0));
        if (viewNormal.z <= 1e-6) return;
      }
      final brightness =
          0.44 + 0.56 * math.max(0.0, worldNormal.dot(lightDir));

      // View-space z: more negative = farther from the camera.
      final za = view.transformed3(a).z;
      final zb = view.transformed3(b).z;
      final zc = view.transformed3(c).z;

      visible.add(_Tri(
        screenA,
        screenB,
        screenC,
        depth: (za + zb + zc) / 3,
        order: index,
        brightness: brightness.clamp(0.0, 1.0),
        base: tri.color,
      ));
      index++;
    }

    for (final tri in RocketMesh.mesh(showNoseCone: showNoseCone)) {
      final n4 = model.transformed3(tri.normal);
      push(tri, model, n4.normalized());
    }
    if (showParachute) {
      for (final tri in ParachuteMesh.triangles) {
        // Unrotated frame: mesh normals are already world-aligned.
        push(tri, chuteModel, tri.normal.normalized());
      }
    }
    visible.sort((x, y) {
      final d = x.depth.compareTo(y.depth);
      return d != 0 ? d : x.order.compareTo(y.order);
    });

    for (final tri in visible) {
      final color = Color.fromARGB(
        255,
        (tri.base.r * 255 * tri.brightness).round().clamp(0, 255),
        (tri.base.g * 255 * tri.brightness).round().clamp(0, 255),
        (tri.base.b * 255 * tri.brightness).round().clamp(0, 255),
      );

      final path = Path()
        ..moveTo(tri.a.dx, tri.a.dy)
        ..lineTo(tri.b.dx, tri.b.dy)
        ..lineTo(tri.c.dx, tri.c.dy)
        ..close();

      // Hairline stroke of the same color hides rasterization seams.
      canvas.drawPath(path, Paint()..color = color);
      canvas.drawPath(
        path,
        Paint()
          ..color = color
          ..style = PaintingStyle.stroke
          ..strokeWidth = 0.6,
      );
    }
  }

  /// Clip-space → NDC → pixel coordinates; `null` when behind the camera.
  Offset? _toScreen(Vector3 world, Matrix4 vp, Size size) {
    final clip = vp.transformed(Vector4(world.x, world.y, world.z, 1));
    if (clip.w <= 0.001) return null;
    final ndc = clip.xyz / clip.w;
    return Offset(
      (ndc.x * 0.5 + 0.5) * size.width,
      (0.5 - ndc.y * 0.5) * size.height,
    );
  }

  /// Corner compass: North / East / Up world axes, projected with the same
  /// camera rotation as the flight-path view (E amber, U green, N blue — the
  /// same language there). Axes pointing away from the camera are dimmed and
  /// shorten, so the gizmo stays stable while orbiting.
  void _paintAxisGizmo(
    Canvas canvas,
    Size size,
    Matrix4 view,
  ) {
    final origin = Offset(32, size.height - 36);
    const len = 24.0;
    const eyeDist = 3.2;

    // Camera basis from the view matrix rows (rigid transform, no scale):
    // right, up, and camera-backward. A world direction d maps to view space
    // via dot products with these.
    final r = view.getRow(0).xyz;
    final u = view.getRow(1).xyz;
    final b = view.getRow(2).xyz;

    // Perspective-correct projection of a world direction. The axis endpoint
    // sits one world unit from the gizmo origin, so axes pointing at (or
    // away from) the camera smoothly grow/shrink instead of flipping around
    // when they cross the view axis.
    ({Offset offset, double toward}) project(Vector3 dirRaw) {
      final d = dirRaw.normalized();
      final vx = d.dot(r);
      final vy = d.dot(u);
      final vz = d.dot(b);
      final s = len * eyeDist / math.max(0.8, eyeDist - vz);
      return (offset: Offset(vx * s, -vy * s), toward: vz);
    }

    final axes = <(Color, String, ({Offset offset, double toward}))>[
      // Model world matches the flight view: X east, Y up, Z south.
      (AppColors.warning, 'E', project(Vector3(1, 0, 0))),
      (AppColors.success, 'U', project(Vector3(0, 1, 0))),
      (AppColors.info, 'N', project(Vector3(0, 0, -1))),
    ]..sort((x, y) => x.$3.toward.compareTo(y.$3.toward));

    for (final (color, label, projected) in axes) {
      final end = origin + projected.offset;
      // Axes pointing away from the camera render dimmed, like hollow gizmo
      // axes in 3D editors.
      final toward = projected.toward;
      final alpha = toward < -0.15 ? 0.35 : 1.0;
      final lineColor = color.withValues(alpha: alpha);
      canvas.drawLine(
        origin,
        end,
        Paint()
          ..color = lineColor
          ..strokeWidth = 1.8
          ..strokeCap = StrokeCap.round,
      );
      final tp = TextPainter(
        text: TextSpan(
          text: label,
          style: TextStyle(
            fontSize: 8,
            fontWeight: FontWeight.w700,
            color: lineColor,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, end + const Offset(2, -10));
    }
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

/// One projected, shaded triangle.
class _Tri {
  final Offset a, b, c;
  final double depth;

  /// Mesh order — stabilises the sort when coplanar faces tie on depth.
  final int order;
  final double brightness;
  final Color base;

  const _Tri(this.a, this.b, this.c,
      {required this.depth,
      required this.order,
      required this.brightness,
      required this.base});
}
