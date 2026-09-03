import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:vector_math/vector_math_64.dart';

/// One flat-shaded triangle of the parametric rocket mesh.
class RocketMeshTri {
  final Vector3 a, b, c;
  final Vector3 normal;
  final Color color;

  RocketMeshTri(this.a, this.b, this.c, this.color)
      : normal = (b - a).cross(c - a).normalized();
}

/// Parametric rocket mesh shared by the orientation viewer and the flight
/// path view: body tube, nose cone, three fins, bottom cap.
///
/// Model space: nose along +Y, base at y = -0.62, tip at y = +0.78.
abstract final class RocketMesh {
  static const int _segments = 20;
  static const double _bodyRadius = 0.17;
  static const double _bodyTop = 0.32;
  static const double _bodyBottom = -0.62;
  static const double _noseTip = 0.78;
  static const double _finSpan = 0.26;

  static final Color _bodyColor = const Color(0xFFE8E8EC);
  static final Color _noseColor = const Color(0xFFDC2626);
  static final Color _finColor = const Color(0xFF52525B);

  static final List<RocketMeshTri> triangles = _build();

  static List<RocketMeshTri> _build() {
    final tris = <RocketMeshTri>[];

    Vector3 ring(double y, double radius, int i) {
      final angle = i * 2 * math.pi / _segments;
      return Vector3(radius * math.cos(angle), y, radius * math.sin(angle));
    }

    // Body tube.
    for (var i = 0; i < _segments; i++) {
      final a0 = ring(_bodyBottom, _bodyRadius, i);
      final a1 = ring(_bodyBottom, _bodyRadius, i + 1);
      final b0 = ring(_bodyTop, _bodyRadius, i);
      final b1 = ring(_bodyTop, _bodyRadius, i + 1);
      tris.addAll(_quad(b0, b1, a1, a0, _bodyColor));
    }

    // Bottom cap.
    final center = Vector3(0, _bodyBottom, 0);
    for (var i = 0; i < _segments; i++) {
      final a0 = ring(_bodyBottom, _bodyRadius, i);
      final a1 = ring(_bodyBottom, _bodyRadius, i + 1);
      tris.add(RocketMeshTri(center, a1, a0, _finColor));
    }

    // Nose cone.
    final tip = Vector3(0, _noseTip, 0);
    for (var i = 0; i < _segments; i++) {
      final b0 = ring(_bodyTop, _bodyRadius, i);
      final b1 = ring(_bodyTop, _bodyRadius, i + 1);
      tris.add(RocketMeshTri(tip, b0, b1, _noseColor));
    }

    // Three fins, 120° apart. Each fin is a swept quad in the plane spanned
    // by the radial direction and the long axis, double-sided.
    for (var f = 0; f < 3; f++) {
      final angle = f * 2 * math.pi / 3;
      final radial = Vector3(math.cos(angle), 0, math.sin(angle));
      final inner = _bodyRadius * 0.98;

      Vector3 pointAt(double alongY, double out) =>
          radial.scaled(out) + Vector3(0, alongY, 0);

      final rootBottom = pointAt(_bodyBottom, inner);
      final rootTop = pointAt(_bodyBottom + 0.34, inner);
      final tipBottom = pointAt(_bodyBottom + 0.06, inner + _finSpan);
      final tipTop = pointAt(_bodyBottom + 0.22, inner + _finSpan);

      tris.addAll(_quad(rootTop, tipTop, tipBottom, rootBottom, _finColor));
      // Back face so fins are visible from both sides.
      tris.addAll(_quad(rootTop, rootBottom, tipBottom, tipTop, _finColor));
    }

    return tris;
  }

  /// Two triangles for quad (a, b, c, d).
  static List<RocketMeshTri> _quad(
      Vector3 a, Vector3 b, Vector3 c, Vector3 d, Color color) {
    return [RocketMeshTri(a, b, c, color), RocketMeshTri(a, c, d, color)];
  }

  /// Rocket-oriented attitude (pitch = tilt from vertical, yaw = compass
  /// heading, roll = spin about the long axis) as a model matrix that maps
  /// the mesh into world space with the nose along the flight direction,
  /// uniformly scaled to [scale] world units.
  static Matrix4 orientationMatrix({
    required double pitchDeg,
    required double yawDeg,
    double rollDeg = 0,
    double scale = 1.0,
  }) {
    final p = pitchDeg.clamp(0, 120) * math.pi / 180;
    final yaw = yawDeg * math.pi / 180;

    final nose = Vector3(
      math.sin(p) * math.sin(yaw),
      math.cos(p),
      math.sin(p) * math.cos(yaw),
    );
    final right = Vector3(math.cos(yaw), 0, -math.sin(yaw));
    final back = nose.cross(right).normalized();

    final orientation = Matrix4.zero();
    orientation.setColumn(0, Vector4(right.x, right.y, right.z, 0));
    orientation.setColumn(1, Vector4(nose.x, nose.y, nose.z, 0));
    orientation.setColumn(2, Vector4(back.x, back.y, back.z, 0));
    orientation.setColumn(3, Vector4(0, 0, 0, 1));

    final model = orientation * (Matrix4.identity()..rotateY(radians(rollDeg)));
    model.scaleByDouble(scale, scale, scale, 1.0);
    return model;
  }
}
