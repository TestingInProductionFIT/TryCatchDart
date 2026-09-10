import 'dart:async';

import 'package:flutter/gestures.dart' show PointerScrollEvent;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../components/tool_button.dart';
import './flight_3d_common.dart';
import './orbit_camera.dart';

/// Shared camera state for the 3D flight views (plain + satellite): chase /
/// orbit-field / free-orbit mode, wheel-zoom, and the slow auto-rotation
/// ticker for the orbit-field camera (shared angles, so both views follow).
mixin Flight3dShellState<T extends ConsumerStatefulWidget> on ConsumerState<T> {
  FlightCameraMode mode = FlightCameraMode.chase;
  double zoom = 1.0;

  Timer? _orbitTicker;

  @override
  void initState() {
    super.initState();
    _orbitTicker = Timer.periodic(const Duration(milliseconds: 50), (_) {
      if (!mounted || mode != FlightCameraMode.orbit) return;
      ref.read(orbitCameraProvider.notifier).autoRotate(0.35);
    });
  }

  @override
  void dispose() {
    _orbitTicker?.cancel();
    super.dispose();
  }

  void orbitBy(Offset delta) {
    ref.read(orbitCameraProvider.notifier).orbit(delta, minEl: -15, maxEl: 80);
  }

  void zoomBy(double factor) {
    setState(() => zoom = (zoom * factor).clamp(0.25, 6.0));
  }

  void resetZoom() => setState(() => zoom = 1.0);

  void setShellMode(FlightCameraMode next) {
    // Switching cameras resets the zoom but keeps the orbit rotation, so the
    // view direction never jumps unexpectedly.
    setState(() {
      mode = next;
      zoom = 1.0;
    });
  }
}

/// Shared chrome around both 3D flight painters: gesture canvas (drag orbits,
/// wheel zooms, double-tap resets) and the camera-mode + zoom tool column.
/// Satellite-only extras (imagery credit) go in [extraOverlays].
class Flight3dShell extends StatelessWidget {
  final CustomPainter painter;
  final FlightCameraMode mode;
  final ValueChanged<FlightCameraMode> onMode;
  final ValueChanged<double> onZoomBy;
  final VoidCallback onResetZoom;
  final ValueChanged<Offset> onOrbit;
  final List<Widget> extraOverlays;

  const Flight3dShell({
    super.key,
    required this.painter,
    required this.mode,
    required this.onMode,
    required this.onZoomBy,
    required this.onResetZoom,
    required this.onOrbit,
    this.extraOverlays = const [],
  });

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        Listener(
          onPointerSignal: (event) {
            if (event is! PointerScrollEvent) return;
            // Scroll up zooms in, scroll down zooms out.
            onZoomBy(event.scrollDelta.dy > 0 ? 1 / 1.1 : 1.1);
          },
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onPanUpdate: (details) => onOrbit(details.delta),
            onDoubleTap: onResetZoom,
            child: CustomPaint(
              painter: painter,
              child: const SizedBox.expand(),
            ),
          ),
        ),
        // Camera mode + zoom buttons.
        Positioned(
          right: 8,
          top: 8,
          child: Column(
            children: [
              for (final m in FlightCameraMode.values)
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: ToolFab(
                    icon: m.icon,
                    tooltip: m.label,
                    active: mode == m,
                    onTap: () => onMode(m),
                  ),
                ),
              const SizedBox(height: 2),
              ToolFab(
                icon: Icons.add,
                tooltip: 'Zoom in',
                active: false,
                onTap: () => onZoomBy(1.25),
              ),
              const SizedBox(height: 6),
              ToolFab(
                icon: Icons.remove,
                tooltip: 'Zoom out',
                active: false,
                onTap: () => onZoomBy(1 / 1.25),
              ),
            ],
          ),
        ),
        ...extraOverlays,
      ],
    );
  }
}
