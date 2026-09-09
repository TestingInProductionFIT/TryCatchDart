import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Orbit angles shared by every 3D view (rocket orientation, flight path,
/// satellite): dragging one rotates all of them, so the rocket's attitude
/// and its trail always read from the same direction.
///
/// Zoom and camera mode stay per-widget — only the look direction is shared.
class OrbitCameraState {
  final double azimuthDeg;
  final double elevationDeg;

  const OrbitCameraState({
    required this.azimuthDeg,
    required this.elevationDeg,
  });
}

final orbitCameraProvider =
    NotifierProvider<OrbitCameraController, OrbitCameraState>(
  OrbitCameraController.new,
);

class OrbitCameraController extends Notifier<OrbitCameraState> {
  @override
  OrbitCameraState build() =>
      const OrbitCameraState(azimuthDeg: -35, elevationDeg: 16);

  /// Applies a drag delta. Elevation limits are per-view (the attitude
  /// viewer allows swinging underneath; the world views don't).
  void orbit(Offset delta, {double minEl = -85, double maxEl = 85}) {
    state = OrbitCameraState(
      azimuthDeg: (state.azimuthDeg - delta.dx * 0.4) % 360,
      elevationDeg:
          (state.elevationDeg + delta.dy * 0.4).clamp(minEl, maxEl),
    );
  }

  /// Shared nudge for the orbit-field auto-rotation.
  void autoRotate(double stepDeg) {
    state = OrbitCameraState(
      azimuthDeg: (state.azimuthDeg + stepDeg) % 360,
      elevationDeg: state.elevationDeg,
    );
  }
}
