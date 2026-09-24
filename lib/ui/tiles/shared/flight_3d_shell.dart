import 'dart:async';

import 'package:flutter/gestures.dart'
    show PointerPanZoomUpdateEvent, PointerScrollEvent;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../components/tool_button.dart';
import '../../screens/tile_leaf_scope.dart';
import './flight_3d_common.dart';
import './orbit_camera.dart';
import './trackpad_zoom.dart' show scrollZoomFactor;

/// Shared camera state for the 3D flight views (plain + satellite): chase /
/// onboard / orbit-field / free-orbit mode, wheel-zoom, and the slow auto-rotation
/// ticker for the orbit-field camera (shared angles, so both views follow).
///
/// The onboard view is the exception to the shared look direction: its lens
/// is strapped to the airframe (side view, nose up, fixed slight down-tilt,
/// following pitch/yaw/roll) at a fixed zoom, and dragging only spins the
/// gaze around the rocket's long axis via [onboardAzimuthDeg] — no user
/// tilt, no zoom. Neither shared orbiting moves the onboard lens nor
/// onboard dragging rotates the other views.
mixin Flight3dShellState<T extends ConsumerStatefulWidget> on ConsumerState<T> {
  FlightCameraMode mode = FlightCameraMode.chase;
  double zoom = 1.0;

  /// Onboard spin (degrees) around the rocket's long axis from the pure
  /// side view, per tile. Zero means exactly sideways, tilted down by
  /// [onboardDownTiltDeg]. The lens has a fixed down-tilt, so there is no
  /// user elevation counterpart.
  double onboardAzimuthDeg = 0.0;

  /// Per-tile easing for the strap-down onboard attitude (jitter melts,
  /// jumps snap — see [OnboardAttitudeSmoother]).
  final OnboardAttitudeSmoother onboardSmoother =
      OnboardAttitudeSmoother();

  /// Scene copy whose attitude has been eased one tick for the onboard
  /// lens. Call once per build while in onboard mode; other modes (and the
  /// trail/extents) always use the raw scene.
  FlightScene smoothOnboardScene(FlightScene scene) {
    onboardSmoother.update(
      pitchDeg: scene.pitchDeg,
      yawDeg: scene.yawDeg,
      rollDeg: scene.rollDeg,
    );
    return scene.withAttitude(
      pitchDeg: onboardSmoother.pitchDeg,
      yawDeg: onboardSmoother.yawDeg,
      rollDeg: onboardSmoother.rollDeg,
    );
  }

  Timer? _orbitTicker;
  bool _leafModeRestored = false;

  @override
  void initState() {
    super.initState();
    _orbitTicker = Timer.periodic(const Duration(milliseconds: 50), (_) {
      if (!mounted || mode != FlightCameraMode.orbit) return;
      ref.read(orbitCameraProvider.notifier).autoRotate(0.35);
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Restore the persisted camera mode once (fresh tiles without a scope,
    // or leaves storing none, keep the default chase view).
    if (!_leafModeRestored) {
      _leafModeRestored = true;
      final initial = TileLeafScope.of(context)?.cameraMode;
      if (initial != null) mode = initial;
    }
  }

  @override
  void dispose() {
    _orbitTicker?.cancel();
    super.dispose();
  }

  void orbitBy(Offset delta) {
    // Onboard only spins around the rocket's long axis (see above): the
    // vertical drag component is dropped, so the user can never tilt off
    // the fixed down-tilt plane. Every other mode orbits the shared angles
    // so all views rotate together.
    if (mode == FlightCameraMode.onboard) {
      setState(() {
        onboardAzimuthDeg = (onboardAzimuthDeg - delta.dx * 0.4) % 360;
      });
      return;
    }
    ref.read(orbitCameraProvider.notifier).orbit(delta, minEl: -15, maxEl: 80);
  }

  void zoomBy(double factor) {
    // The onboard lens is fixed (a real strap-down camera has no zoom).
    if (mode == FlightCameraMode.onboard) return;
    setState(() => zoom = (zoom * factor).clamp(0.2, 8.0));
  }

  void resetZoom() {
    // Double-tap recenters the onboard spin (zoom is fixed onboard).
    if (mode == FlightCameraMode.onboard) {
      setState(() => onboardAzimuthDeg = 0.0);
      return;
    }
    setState(() => zoom = 1.0);
  }

  void setShellMode(FlightCameraMode next) {
    // Switching cameras resets the zoom but keeps the orbit rotation, so the
    // view direction never jumps unexpectedly. Entering onboard restarts its
    // easing from the live attitude instead of slewing over from stale data.
    // The selection is reported to the workspace leaf so the save file (and
    // the promote-to-defaults output) follows the live UI.
    setState(() {
      mode = next;
      zoom = 1.0;
      if (next == FlightCameraMode.onboard) onboardSmoother.reset();
    });
    TileLeafScope.of(context)?.onCameraMode?.call(next);
  }
}

/// Shared chrome around both 3D flight painters: gesture canvas (drag orbits,
/// wheel/pinch zooms, double-tap resets zoom) and the camera-mode tool
/// column. Satellite-only extras (imagery credit) go in [extraOverlays].
///
/// Trackpad gestures arrive as pointer pan/zoom events rather than wheel
/// scrolls, and the framework routes their swipe component to drag
/// recognizers — without suppression a two-finger swipe would both zoom
/// (here) and tilt (via [onOrbit]). While a trackpad gesture is active the
/// swipe/pinch zooms and drag-orbit is ignored; a real press always clears
/// the flag so a lost gesture-end can never wedge orbiting off.
class Flight3dShell extends StatefulWidget {
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
  State<Flight3dShell> createState() => _Flight3dShellState();
}

class _Flight3dShellState extends State<Flight3dShell> {
  bool _trackpadZooming = false;
  double _lastScale = 1.0;

  void _trackpadZoom(PointerPanZoomUpdateEvent event) {
    _trackpadZooming = true;
    final factor =
        scrollZoomFactor(event.panDelta.dy) * (event.scale / _lastScale);
    _lastScale = event.scale;
    if (factor != 1.0) widget.onZoomBy(factor);
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        Listener(
          onPointerSignal: (event) {
            if (event is! PointerScrollEvent) return;
            // Scroll up zooms in, scroll down zooms out.
            widget.onZoomBy(event.scrollDelta.dy > 0 ? 1 / 1.1 : 1.1);
          },
          onPointerPanZoomStart: (_) {
            _trackpadZooming = true;
            _lastScale = 1.0;
          },
          onPointerPanZoomUpdate: _trackpadZoom,
          onPointerPanZoomEnd: (_) => _trackpadZooming = false,
          onPointerDown: (_) => _trackpadZooming = false,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onPanUpdate: (details) {
              if (_trackpadZooming) return;
              widget.onOrbit(details.delta);
            },
            onDoubleTap: widget.onResetZoom,
            child: CustomPaint(
              painter: widget.painter,
              child: const SizedBox.expand(),
            ),
          ),
        ),
        // Camera mode buttons (zoom lives in wheel/pinch/double-tap only).
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
                    active: widget.mode == m,
                    onTap: () => widget.onMode(m),
                  ),
                ),
            ],
          ),
        ),
        ...widget.extraOverlays,
      ],
    );
  }
}
