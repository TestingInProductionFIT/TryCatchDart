import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart' show PointerScrollEvent;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:serial/serial.dart';
// `Colors` collides with material's — material's wins here.
import 'package:vector_math/vector_math_64.dart' hide Colors;

import '../../settings/launch_site_store.dart';
import '../../src/geo/geo.dart';
import '../../src/telemetry/telemetry_store.dart';
import '../../theme/app_colors.dart';
import '../../theme/widgets/waiting_for_data.dart';
import 'rocket_mesh.dart';

/// Camera behaviour of the 3D flight view.
enum FlightCameraMode {
  chase('Chase rocket', Icons.center_focus_strong),
  orbit('Orbit field', Icons.threesixty),
  free('Free orbit', Icons.control_camera);

  final String label;
  final IconData icon;

  const FlightCameraMode(this.label, this.icon);
}

/// 3D flight path view: the rocket flies through a metric world (east/up/
/// north metres relative to the launch site), leaving its trail behind it.
/// The launch site is marked with a flag on a gridded ground plane, and the
/// camera can chase the rocket, orbit the whole field, or orbit freely.
///
/// Positions come from GPS fixes with dead-reckoning points interleaved by
/// time, so GPS dropouts stay connected. Same software renderer approach as
/// [Rocket3dWidget]; the rocket mesh is shared.
class Flight3dWidget extends ConsumerStatefulWidget {
  const Flight3dWidget({super.key});

  @override
  ConsumerState<Flight3dWidget> createState() => _Flight3dWidgetState();
}

class _Flight3dWidgetState extends ConsumerState<Flight3dWidget> {
  FlightCameraMode _mode = FlightCameraMode.chase;
  double _azimuthDeg = 215;
  double _elevationDeg = 18;
  double _zoom = 1.0;

  /// Slow auto-rotation for the "orbit field" camera.
  Timer? _orbitTicker;

  @override
  void initState() {
    super.initState();
    _orbitTicker = Timer.periodic(const Duration(milliseconds: 50), (_) {
      if (!mounted || _mode != FlightCameraMode.orbit) return;
      setState(() => _azimuthDeg = (_azimuthDeg + 0.35) % 360);
    });
  }

  @override
  void dispose() {
    _orbitTicker?.cancel();
    super.dispose();
  }

  void _orbit(Offset delta) {
    setState(() {
      _azimuthDeg = (_azimuthDeg - delta.dx * 0.4) % 360;
      _elevationDeg = (_elevationDeg + delta.dy * 0.4).clamp(-15.0, 85.0);
    });
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(telemetryStoreProvider);
    final site = ref.watch(currentLaunchSiteProvider);
    final latest = state.latest;

    if (latest == null) {
      return const Center(child: WaitingForData());
    }

    final scene = _buildScene(state, site);
    if (scene == null) {
      // Frames are arriving but no position anchor (no fix, no site) yet.
      return const Center(child: WaitingForData());
    }

    return Stack(
      fit: StackFit.expand,
      children: [
        Listener(
          onPointerSignal: (event) {
            if (event is! PointerScrollEvent) return;
            final factor = event.scrollDelta.dy > 0 ? 1.1 : 1 / 1.1;
            setState(() => _zoom = (_zoom * factor).clamp(0.25, 6.0));
          },
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onPanUpdate: (details) => _orbit(details.delta),
            child: CustomPaint(
              painter: _FlightPainter(
                scene: scene,
                mode: _mode,
                azimuthDeg: _azimuthDeg,
                elevationDeg: _elevationDeg,
                zoom: _zoom,
              ),
              child: const SizedBox.expand(),
            ),
          ),
        ),
        // Camera mode buttons.
        Positioned(
          right: 8,
          top: 8,
          child: Column(
            children: [
              for (final mode in FlightCameraMode.values)
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: _CamFab(
                    icon: mode.icon,
                    tooltip: mode.label,
                    active: _mode == mode,
                    onTap: () => setState(() => _mode = mode),
                  ),
                ),
            ],
          ),
        ),
        if (scene.chute != _Chute.none)
          Positioned(
            top: 8,
            left: 10,
            child: Tooltip(
              message: scene.chute == _Chute.main
                  ? 'Main parachute deployed'
                  : 'Drogue parachute deployed',
              child: Icon(
                Icons.paragliding,
                size: 20,
                color: scene.chute == _Chute.main
                    ? AppColors.warning
                    : const Color(0xFF0D9488),
              ),
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

  /// Builds the metric scene from the flight history: trail, rocket position,
  /// extents and readout. `null` when no position anchor exists yet.
  _Scene? _buildScene(TelemetryState state, LaunchSite? site) {
    final history = state.history;
    if (history.isEmpty) return null;
    final latest = state.latest!;

    // World origin: the configured launch site, else the first GPS fix.
    double lat0;
    double lon0;
    double groundMsl;
    if (site != null) {
      lat0 = site.latitude;
      lon0 = site.longitude;
      groundMsl = site.altitudeMsl;
    } else {
      TelemetryFrame? firstFix;
      for (var i = 0; i < history.length; i++) {
        final f = history.getChronological(i);
        if (f.gpsHasFix) {
          firstFix = f;
          break;
        }
      }
      if (firstFix == null) return null;
      lat0 = firstFix.latitude;
      lon0 = firstFix.longitude;
      groundMsl = firstFix.gpsAltitude;
    }
    final cosLat0 = math.cos(radians(lat0));

    // Scene axes: X = east, Y = up (AGL), Z = north — all metres.
    Vector3 enu(double lat, double lon, double agl) => Vector3(
          (lon - lon0) * metresPerDegreeLat * cosLat0,
          math.max(0.0, agl),
          (lat - lat0) * metresPerDegreeLat,
        );

    // Trail: GPS fixes decimated on absolute time buckets, with DR points
    // interleaved by time so GPS dropouts stay connected. Each point knows
    // its source so DR segments render in a distinct colour.
    final dr = state.deadReckoningHistory;
    final spanMs = history[0].receivedAtMs -
        history.getChronological(0).receivedAtMs;
    final bucketMs = math.max(1, spanMs ~/ 400);
    final trail = <_TrailPoint>[];
    var lastGpsBucket = -1;
    var lastDrBucket = -1;
    var drIdx = 0;

    void drainDr(int untilMs) {
      while (drIdx < dr.length && dr.getChronological(drIdx).atMs <= untilMs) {
        final p = dr.getChronological(drIdx);
        final bucket = p.atMs ~/ bucketMs;
        if (bucket != lastDrBucket || drIdx == dr.length - 1) {
          trail.add(_TrailPoint(
            enu(p.latitude, p.longitude, p.altitude - groundMsl),
            dr: true,
          ));
          lastDrBucket = bucket;
        }
        drIdx++;
      }
    }

    for (var i = 0; i < history.length; i++) {
      final f = history.getChronological(i);
      drainDr(f.receivedAtMs);
      if (!f.gpsHasFix) continue;
      final bucket = f.receivedAtMs ~/ bucketMs;
      if (bucket == lastGpsBucket) continue;
      trail.add(_TrailPoint(
        enu(f.latitude, f.longitude, f.baroAltitude),
        dr: false,
      ));
      lastGpsBucket = bucket;
    }
    // DR points newer than the last frame (link-loss extrapolation).
    drainDr(1 << 62);

    if (trail.isEmpty) return null;

    // Current rocket position: GPS when available, dead reckoning otherwise.
    final drNow = state.deadReckoning;
    final rocketIsDr = !latest.gpsHasFix && drNow != null;
    Vector3 rocketPos;
    if (latest.gpsHasFix) {
      rocketPos = enu(latest.latitude, latest.longitude, latest.baroAltitude);
    } else if (drNow != null) {
      rocketPos = enu(
          drNow.latitude, drNow.longitude, drNow.altitude - groundMsl);
    } else {
      rocketPos = trail.last.pos;
    }

    var maxAlt = 0.0;
    var maxHoriz = 0.0;
    for (final p in trail) {
      if (p.pos.y > maxAlt) maxAlt = p.pos.y;
      final h = math.sqrt(p.pos.x * p.pos.x + p.pos.z * p.pos.z);
      if (h > maxHoriz) maxHoriz = h;
    }
    final downrange = math.sqrt(
        rocketPos.x * rocketPos.x + rocketPos.z * rocketPos.z);

    return _Scene(
      trail: trail,
      rocketPos: rocketPos,
      rocketIsDr: rocketIsDr,
      maxAlt: maxAlt,
      maxHoriz: maxHoriz,
      pitchDeg: latest.pitch,
      yawDeg: latest.yaw,
      rollDeg: latest.roll,
      chute: switch (latest.fsmState) {
        FsmState.apogee || FsmState.drogue => _Chute.drogue,
        FsmState.main => _Chute.main,
        _ => _Chute.none,
      },
      siteName: site?.name,
      readout:
          'Alt ${rocketPos.y.toStringAsFixed(0)} m · '
          'Downrange ${downrange.toStringAsFixed(0)} m'
          '${rocketIsDr ? ' · DR' : ''}',
    );
  }
}

enum _Chute { none, drogue, main }

/// One trail vertex and where it came from.
class _TrailPoint {
  final Vector3 pos;
  final bool dr;

  const _TrailPoint(this.pos, {required this.dr});
}

/// Everything the painter needs, rebuilt on every telemetry tick.
class _Scene {
  final List<_TrailPoint> trail;
  final Vector3 rocketPos;

  /// `true` when [rocketPos] is a dead-reckoning estimate (GPS stale).
  final bool rocketIsDr;
  final double maxAlt;
  final double maxHoriz;
  final double pitchDeg;
  final double yawDeg;
  final double rollDeg;
  final _Chute chute;
  final String? siteName;
  final String readout;

  const _Scene({
    required this.trail,
    required this.rocketPos,
    required this.rocketIsDr,
    required this.maxAlt,
    required this.maxHoriz,
    required this.pitchDeg,
    required this.yawDeg,
    required this.rollDeg,
    required this.chute,
    required this.siteName,
    required this.readout,
  });
}

// ── Renderer ─────────────────────────────────────────────────────────────────

class _FlightPainter extends CustomPainter {
  final _Scene scene;
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

    // Camera target/distance: on the rocket, or orbiting the whole field.
    final center = Vector3(0, scene.maxAlt * 0.45, 0);
    final sceneRadius =
        math.max(40.0, math.max(scene.maxHoriz, scene.maxAlt));
    final (Vector3 target, double dist) = switch (mode) {
      FlightCameraMode.chase => (
          scene.rocketPos,
          math.max(24.0, sceneRadius * 0.16) / zoom,
        ),
      _ => (
          center,
          math.max(60.0, sceneRadius * 2.2) / zoom,
        ),
    };

    final az = radians(azimuthDeg);
    final el = radians(elevationDeg.clamp(-15.0, 85.0));
    final camDir = Vector3(
      math.cos(el) * math.sin(az),
      math.sin(el),
      math.cos(el) * math.cos(az),
    );
    var eye = target + camDir * dist;
    if (eye.y < 2.0) eye = Vector3(eye.x, 2.0, eye.z);

    final proj = makePerspectiveMatrix(radians(50), aspect, 0.5, dist + sceneRadius * 4 + 500);
    final view = makeViewMatrix(eye, target, Vector3(0, 1, 0));
    final vp = proj * view;

    // Headlight slightly above the camera, like the orientation viewer.
    final light = (camDir.clone()..scale(0.6)) + Vector3(-0.25, 0.8, 0.1);
    final lightDir = light.normalized();

    _paintGround(canvas, size, vp);
    // Trail: solid blue GPS, violet dead reckoning.
    final gpsPaint = Paint()
      ..color = AppColors.seriesGpsTrack.withValues(alpha: 0.85)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.2
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final drPaint = Paint()
      ..color = AppColors.seriesDeadReckoning.withValues(alpha: 0.85)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    for (var i = 1; i < scene.trail.length; i++) {
      final a = _project(scene.trail[i - 1].pos, vp, size);
      final b = _project(scene.trail[i].pos, vp, size);
      if (a == null || b == null) continue;
      canvas.drawLine(
        a,
        b,
        scene.trail[i].dr || scene.trail[i - 1].dr ? drPaint : gpsPaint,
      );
    }
    _paintLaunchSite(canvas, size, vp);
    // Drop line from the rocket to the ground reads altitude at a glance.
    _drawSegment(
      canvas,
      scene.rocketPos,
      Vector3(scene.rocketPos.x, 0, scene.rocketPos.z),
      vp,
      size,
      Paint()
        ..color = AppColors.mutedForeground.withValues(alpha: 0.45)
        ..strokeWidth = 1,
    );
    // When the shown position is dead-reckoned, ring it violet so it is not
    // mistaken for a GPS fix.
    if (scene.rocketIsDr) {
      final s = _project(scene.rocketPos, vp, size);
      if (s != null) {
        canvas.drawCircle(
          s,
          11,
          Paint()
            ..color = AppColors.seriesDeadReckoning.withValues(alpha: 0.9)
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2,
        );
        canvas.drawCircle(
          s,
          2,
          Paint()..color = AppColors.seriesDeadReckoning,
        );
      }
    }
    _paintRocket(canvas, size, vp, view, lightDir);
  }

  void _paintGround(Canvas canvas, Size size, Matrix4 vp) {
    final gridHalf = _niceCeil(
        math.max(60.0, math.max(scene.maxHoriz * 1.3, scene.maxAlt * 0.6)));
    final step = _niceCeil(gridHalf / 8);
    final n = (gridHalf / step).ceil();
    final half = n * step;

    // Subtle ground fill.
    final c0 = _project(Vector3(-half, 0, -half), vp, size);
    final c1 = _project(Vector3(half, 0, -half), vp, size);
    final c2 = _project(Vector3(half, 0, half), vp, size);
    final c3 = _project(Vector3(-half, 0, half), vp, size);
    if (c0 != null && c1 != null && c2 != null && c3 != null) {
      canvas.drawPath(
        Path()
          ..moveTo(c0.dx, c0.dy)
          ..lineTo(c1.dx, c1.dy)
          ..lineTo(c2.dx, c2.dy)
          ..lineTo(c3.dx, c3.dy)
          ..close(),
        Paint()..color = AppColors.muted.withValues(alpha: 0.65),
      );
    }

    final gridLine = Paint()
      ..color = AppColors.border
      ..strokeWidth = 1;
    final axisLine = Paint()
      ..color = AppColors.strongBorder
      ..strokeWidth = 1.4;
    for (var k = -n; k <= n; k++) {
      final off = k * step;
      final paint = k == 0 ? axisLine : gridLine;
      _drawSegment(canvas, Vector3(off, 0, -half), Vector3(off, 0, half), vp,
          size, paint);
      _drawSegment(canvas, Vector3(-half, 0, off), Vector3(half, 0, off), vp,
          size, paint);
    }
  }

  void _paintLaunchSite(Canvas canvas, Size size, Matrix4 vp) {
    // Flag pole with a small pennant.
    _drawSegment(
      canvas,
      Vector3.zero(),
      Vector3(0, 10, 0),
      vp,
      size,
      Paint()
        ..color = AppColors.pinkDeep
        ..strokeWidth = 1.6,
    );
    final tip = _project(Vector3(0, 10, 0), vp, size);
    final tail = _project(Vector3(0, 7.5, 0), vp, size);
    final point = _project(Vector3(2.6, 8.75, 0), vp, size);
    if (tip != null && tail != null && point != null) {
      canvas.drawPath(
        Path()
          ..moveTo(tip.dx, tip.dy)
          ..lineTo(point.dx, point.dy)
          ..lineTo(tail.dx, tail.dy)
          ..close(),
        Paint()..color = AppColors.pinkDeep,
      );
    }
    // Pad ring.
    _drawGroundCircle(
      canvas,
      Vector3.zero(),
      8,
      vp,
      size,
      Paint()
        ..color = AppColors.pinkDeep.withValues(alpha: 0.55)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.4,
    );

    final labelPos = _project(Vector3(0, 13, 0), vp, size);
    if (labelPos == null) return;
    final tp = TextPainter(
      text: TextSpan(
        text: scene.siteName == null || scene.siteName!.isEmpty
            ? 'Launch site'
            : 'Launch site · ${scene.siteName}',
        style: AppText.microLabel.copyWith(
          fontSize: 9,
          letterSpacing: 1,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, labelPos + const Offset(4, -6));
  }

  void _paintRocket(
    Canvas canvas,
    Size size,
    Matrix4 vp,
    Matrix4 view,
    Vector3 lightDir,
  ) {
    final model = Matrix4.translation(scene.rocketPos) *
        RocketMesh.orientationMatrix(
          pitchDeg: scene.pitchDeg,
          yawDeg: scene.yawDeg,
          rollDeg: scene.rollDeg,
          scale: _rocketScale,
        );

    final visible = <_Tri>[];
    for (final tri in RocketMesh.triangles) {
      final a = model.transformed3(tri.a);
      final b = model.transformed3(tri.b);
      final c = model.transformed3(tri.c);

      final screenA = _project(a, vp, size);
      final screenB = _project(b, vp, size);
      final screenC = _project(c, vp, size);
      if (screenA == null || screenB == null || screenC == null) continue;

      // Normals rotate with the model; strip the translation column.
      final worldNormal =
          (model.transformed3(tri.normal) - scene.rocketPos).normalized();
      final brightness =
          0.44 + 0.56 * math.max(0.0, worldNormal.dot(lightDir));

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

  /// Clip-space → NDC → pixel coordinates; `null` when at/behind the camera.
  Offset? _project(Vector3 world, Matrix4 vp, Size size) {
    final clip = vp.transformed(Vector4(world.x, world.y, world.z, 1));
    if (clip.w <= 0.5) return null;
    final ndc = clip.xyz / clip.w;
    return Offset(
      (ndc.x * 0.5 + 0.5) * size.width,
      (0.5 - ndc.y * 0.5) * size.height,
    );
  }

  void _drawSegment(Canvas canvas, Vector3 a, Vector3 b, Matrix4 vp, Size size,
      Paint paint) {
    final sa = _project(a, vp, size);
    final sb = _project(b, vp, size);
    if (sa == null || sb == null) return;
    canvas.drawLine(sa, sb, paint);
  }

  void _drawGroundCircle(
      Canvas canvas, Vector3 center, double radius, Matrix4 vp, Size size,
      Paint paint) {
    final path = Path();
    var pen = false;
    for (var i = 0; i <= 32; i++) {
      final a = i * 2 * math.pi / 32;
      final s = _project(
        center + Vector3(radius * math.cos(a), 0, radius * math.sin(a)),
        vp,
        size,
      );
      if (s == null) {
        pen = false;
        continue;
      }
      if (pen) {
        path.lineTo(s.dx, s.dy);
      } else {
        path.moveTo(s.dx, s.dy);
        pen = true;
      }
    }
    canvas.drawPath(path, paint);
  }

  /// Rounds up to a 1-2-5 progression so grid spacing stays readable.
  double _niceCeil(double v) {
    if (v <= 0) return 1;
    final mag =
        math.pow(10, (math.log(v) / math.ln10).floorToDouble()).toDouble();
    for (final m in const [1.0, 2.0, 5.0, 10.0]) {
      if (v <= m * mag) return m * mag;
    }
    return 10 * mag;
  }

  @override
  bool shouldRepaint(covariant _FlightPainter old) =>
      !identical(old.scene, scene) ||
      old.mode != mode ||
      old.azimuthDeg != azimuthDeg ||
      old.elevationDeg != elevationDeg ||
      old.zoom != zoom;
}

class _Tri {
  final Offset a, b, c;
  final double depth;
  final double brightness;
  final Color base;

  const _Tri(this.a, this.b, this.c,
      {required this.depth, required this.brightness, required this.base});
}

class _CamFab extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final bool active;
  final VoidCallback onTap;

  const _CamFab({
    required this.icon,
    required this.tooltip,
    required this.active,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: active ? AppColors.primary : AppColors.card,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppDimens.radiusSmall),
        side: BorderSide(color: active ? Colors.transparent : AppColors.border),
      ),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppDimens.radiusSmall),
        child: Tooltip(
          message: tooltip,
          child: Padding(
            padding: const EdgeInsets.all(6),
            child: Icon(
              icon,
              size: 16,
              color:
                  active ? AppColors.primaryForeground : AppColors.foreground,
            ),
          ),
        ),
      ),
    );
  }
}
