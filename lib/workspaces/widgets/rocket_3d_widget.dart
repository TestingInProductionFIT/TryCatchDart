import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:serial/serial.dart';
import 'package:vector_math/vector_math_64.dart';

import '../../src/telemetry/telemetry_store.dart';
import '../../theme/app_colors.dart';
import '../../theme/widgets/waiting_for_data.dart';
import 'rocket_mesh.dart';

/// 3D rocket orientation view.
///
/// A small software renderer built on `vector_math`: a parametric rocket mesh
/// (body tube, nose cone, three fins) is transformed by the rocket's attitude,
/// lit with flat shading and depth-sorted (painter's algorithm). Drag orbits
/// the camera; a corner gizmo shows the world and rocket axes.
///
/// Attitude is rocket-oriented: pitch = tilt from vertical, yaw = heading,
/// roll = spin around the longitudinal axis.
class Rocket3dWidget extends ConsumerStatefulWidget {
  const Rocket3dWidget({super.key});

  @override
  ConsumerState<Rocket3dWidget> createState() => _Rocket3dWidgetState();
}

class _Rocket3dWidgetState extends ConsumerState<Rocket3dWidget> {
  double _cameraAzimuthDeg = -35;
  double _cameraElevationDeg = 16;

  void _orbit(Offset delta) {
    setState(() {
      _cameraAzimuthDeg = (_cameraAzimuthDeg - delta.dx * 0.4) % 360;
      _cameraElevationDeg =
          (_cameraElevationDeg + delta.dy * 0.4).clamp(-85.0, 85.0);
    });
  }

  @override
  Widget build(BuildContext context) {
    final latest = ref.watch(telemetryStoreProvider).latest;

    if (latest == null) {
      return const Center(child: WaitingForData());
    }

    final chute = switch (latest.fsmState) {
      FsmState.apogee || FsmState.drogue => _Chute.drogue,
      FsmState.main => _Chute.main,
      _ => _Chute.none,
    };

    return Stack(
      fit: StackFit.expand,
      children: [
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onPanUpdate: (details) => _orbit(details.delta),
          child: CustomPaint(
            painter: _RocketPainter(
              pitchDeg: latest.pitch,
              yawDeg: latest.yaw,
              rollDeg: latest.roll,
              cameraAzimuthDeg: _cameraAzimuthDeg,
              cameraElevationDeg: _cameraElevationDeg,
            ),
            child: const SizedBox.expand(),
          ),
        ),
        if (chute != _Chute.none)
          Positioned(
            top: 8,
            right: 10,
            child: Tooltip(
              message: chute == _Chute.main
                  ? 'Main parachute deployed'
                  : 'Drogue parachute deployed',
              child: Icon(
                Icons.paragliding,
                size: 20,
                color: chute == _Chute.main
                    ? AppColors.warning
                    : const Color(0xFF0D9488),
              ),
            ),
          ),
      ],
    );
  }
}

enum _Chute { none, drogue, main }

// ── Renderer ─────────────────────────────────────────────────────────────────

class _RocketPainter extends CustomPainter {
  final double pitchDeg;
  final double yawDeg;
  final double rollDeg;
  final double cameraAzimuthDeg;
  final double cameraElevationDeg;

  _RocketPainter({
    required this.pitchDeg,
    required this.yawDeg,
    required this.rollDeg,
    required this.cameraAzimuthDeg,
    required this.cameraElevationDeg,
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
    final view = makeViewMatrix(
      camDir.scaled(3.2), // eye
      Vector3.zero(), // target
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

    _paintMesh(canvas, size, vp, view, model, lightDir);
    _paintAxisGizmo(canvas, size, view);
  }

  void _paintMesh(
    Canvas canvas,
    Size size,
    Matrix4 vp,
    Matrix4 view,
    Matrix4 model,
    Vector3 lightDir,
  ) {
    // Transform all mesh triangles; painter's algorithm by view depth.
    final visible = <_Tri>[];
    for (final tri in RocketMesh.triangles) {
      final a = model.transformed3(tri.a);
      final b = model.transformed3(tri.b);
      final c = model.transformed3(tri.c);

      final screenA = _toScreen(a, vp, size);
      final screenB = _toScreen(b, vp, size);
      final screenC = _toScreen(c, vp, size);
      if (screenA == null || screenB == null || screenC == null) continue;

      final n4 = model.transformed3(tri.normal);
      final worldNormal = n4.normalized();
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
        brightness: brightness.clamp(0.0, 1.0),
        base: tri.color,
      ));
    }
    visible.sort((x, y) => x.depth.compareTo(y.depth));

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

  /// Corner gizmo: world axes X/Y/Z, projected with the same camera
  /// rotation. Axes pointing away from the camera are dimmed and shorten, so
  /// the gizmo stays stable while orbiting.
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
      (AppColors.destructive, 'X', project(Vector3(1, 0, 0))),
      (AppColors.success, 'Y', project(Vector3(0, 1, 0))),
      (AppColors.info, 'Z', project(Vector3(0, 0, 1))),
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
      old.cameraElevationDeg != cameraElevationDeg;
}

/// One projected, shaded triangle.
class _Tri {
  final Offset a, b, c;
  final double depth;
  final double brightness;
  final Color base;

  const _Tri(this.a, this.b, this.c,
      {required this.depth, required this.brightness, required this.base});
}
