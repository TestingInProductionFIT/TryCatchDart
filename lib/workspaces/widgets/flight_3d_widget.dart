import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart' show PointerScrollEvent;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../flights/replay_controller.dart';
import '../../src/telemetry/telemetry_store.dart';
import '../../theme/app_colors.dart';
import '../../theme/widgets/waiting_for_data.dart';
import '../../theme/widgets/tool_button.dart';
import 'flight_3d_common.dart';
import 'orbit_camera.dart';
import 'rocket_mesh.dart';

/// 3D flight path view: the rocket flies through a metric world (east/up/
/// south metres relative to the launch site), leaving its trail behind it.
/// The launch site is marked with a flag on a gridded ground plane, and the
/// camera can chase the rocket, orbit the whole field, or orbit freely.
///
/// Positions come from GPS fixes; a stale GPS estimate is shown as a single
/// violet dead-reckoning point (never a trail). The rocket stands on its tail
/// at the reported position. Scene, cameras and painters are shared with the
/// satellite view ([Flight3dSatelliteWidget]) via `flight_3d_common.dart`.
class Flight3dWidget extends ConsumerStatefulWidget {
  const Flight3dWidget({super.key});

  @override
  ConsumerState<Flight3dWidget> createState() => _Flight3dWidgetState();
}

class _Flight3dWidgetState extends ConsumerState<Flight3dWidget> {
  FlightCameraMode _mode = FlightCameraMode.chase;
  double _zoom = 1.0;

  /// Slow auto-rotation for the "orbit field" camera (shared angles, so the
  /// rocket view follows along).
  Timer? _orbitTicker;

  @override
  void initState() {
    super.initState();
    _orbitTicker = Timer.periodic(const Duration(milliseconds: 50), (_) {
      if (!mounted || _mode != FlightCameraMode.orbit) return;
      ref.read(orbitCameraProvider.notifier).autoRotate(0.35);
    });
  }

  @override
  void dispose() {
    _orbitTicker?.cancel();
    super.dispose();
  }

  void _orbit(Offset delta) {
    ref
        .read(orbitCameraProvider.notifier)
        .orbit(delta, minEl: -15, maxEl: 80);
  }

  void _zoomBy(double factor) {
    setState(() => _zoom = (_zoom * factor).clamp(0.25, 6.0));
  }

  void _setMode(FlightCameraMode mode) {
    // Switching cameras resets the zoom but keeps the orbit rotation, so the
    // view direction never jumps unexpectedly.
    setState(() {
      _mode = mode;
      _zoom = 1.0;
    });
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(telemetryStoreProvider);
    final site = ref.watch(effectiveLaunchSiteProvider);
    final latest = state.latest;
    final camera = ref.watch(orbitCameraProvider);

    if (latest == null) {
      return Center(child: WaitingForData());
    }

    final scene = buildFlightScene(state, site);
    if (scene == null) {
      // Frames are arriving but no position anchor (no fix, no site) yet.
      return Center(child: WaitingForData());
    }

    return Stack(
      fit: StackFit.expand,
      children: [
        Listener(
          onPointerSignal: (event) {
            if (event is! PointerScrollEvent) return;
            // Scroll up zooms in, scroll down zooms out.
            _zoomBy(event.scrollDelta.dy > 0 ? 1 / 1.1 : 1.1);
          },
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onPanUpdate: (details) => _orbit(details.delta),
            onDoubleTap: () => setState(() => _zoom = 1.0),
            child: CustomPaint(
              painter: _FlightPainter(
                scene: scene,
                mode: _mode,
                azimuthDeg: camera.azimuthDeg,
                elevationDeg: camera.elevationDeg,
                zoom: _zoom,
              ),
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
              for (final mode in FlightCameraMode.values)
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: ToolFab(
                    icon: mode.icon,
                    tooltip: mode.label,
                    active: _mode == mode,
                    onTap: () => _setMode(mode),
                  ),
                ),
              const SizedBox(height: 2),
              ToolFab(
                icon: Icons.add,
                tooltip: 'Zoom in',
                active: false,
                onTap: () => _zoomBy(1.25),
              ),
              const SizedBox(height: 6),
              ToolFab(
                icon: Icons.remove,
                tooltip: 'Zoom out',
                active: false,
                onTap: () => _zoomBy(1 / 1.25),
              ),
            ],
          ),
        ),
        Positioned(
          left: 8,
          bottom: 8,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
            decoration: BoxDecoration(
              color: AppColors.card.withValues(alpha: 0.92),
              borderRadius: BorderRadius.circular(AppDimens.radiusSmall),
              border: Border.all(color: AppColors.border),
            ),
            child: Text(
              scene.readout,
              style: AppText.mono.copyWith(
                fontSize: 10.5,
                fontWeight: FontWeight.w700,
                fontFeatures: const [FontFeature.tabularFigures()],
                color: AppColors.mutedForeground,
              ),
            ),
          ),
        ),
      ],
    );
  }
}

// ── Renderer ─────────────────────────────────────────────────────────────────

class _FlightPainter extends CustomPainter {
  final FlightScene scene;
  final FlightCameraMode mode;
  final double azimuthDeg;
  final double elevationDeg;
  final double zoom;

  /// Rocket mesh scaled to a ~5 m airframe so it reads at chase distance.
  static const double _rocketScale = 3.5;

  _FlightPainter({
    required this.scene,
    required this.mode,
    required this.azimuthDeg,
    required this.elevationDeg,
    required this.zoom,
  });

  @override
  void paint(Canvas canvas, Size size) {
    // Nothing may leak outside the widget bounds.
    canvas.clipRect(Offset.zero & size);

    final aspect = size.width / math.max(1.0, size.height);
    final cam = computeFlightCamera(
      scene: scene,
      mode: mode,
      azimuthDeg: azimuthDeg,
      elevationDeg: elevationDeg,
      zoom: zoom,
      aspect: aspect,
    );
    paintGroundPlain(canvas, scene, cam.vp, size);
    paintFlightTrail(canvas, scene, cam.vp, size);
    paintLaunchSite(canvas, scene, cam.vp, size);
    paintDropLineAndDr(canvas, scene, cam.vp, size);
    paintRocketMesh(
      canvas,
      size,
      cam.vp,
      cam.view,
      cam.lightDir,
      rocketPos: scene.rocketPos,
      pitchDeg: scene.pitchDeg,
      yawDeg: scene.yawDeg,
      rollDeg: scene.rollDeg,
      scale: _rocketScale,
      // Stand the airframe on its tail so it never sinks through the plane.
      baseLift: RocketMesh.baseExtent,
      // Airframe configuration comes from the FSM state (cone pops at
      // apogee, canopy opens under parachute).
      showNoseCone: scene.showNoseCone,
      showParachute: scene.showParachute,
    );
    paintCompass(canvas, size, cam.view);
  }

  @override
  bool shouldRepaint(covariant _FlightPainter old) =>
      !identical(old.scene, scene) ||
      old.mode != mode ||
      old.azimuthDeg != azimuthDeg ||
      old.elevationDeg != elevationDeg ||
      old.zoom != zoom;
}
