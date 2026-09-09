import 'dart:math' as math;

import 'package:flutter/material.dart';
// `Colors` collides with material's — material's wins here.
import 'package:vector_math/vector_math_64.dart' hide Colors;

import '../../settings/launch_site_store.dart';
import '../../src/geo/geo.dart';
import '../../src/telemetry/telemetry_store.dart';
import '../../theme/app_colors.dart';
import 'rocket_mesh.dart';

/// Shared scene, camera and painter helpers for the 3D flight views (plain
/// and satellite). Both widgets render the same [FlightScene] with the same
/// cameras; only the ground differs.
///
/// World frame (right-handed, so the standard view matrix never mirrors):
/// X east, Y up (AGL), Z **south** — because E×U=S. (A previous revision used
/// +Z north, a left-handed frame that rendered east/west flipped.)
///
/// The compass language is shared too: E amber, U green, N blue.

/// Camera behaviour of the 3D flight views.
enum FlightCameraMode {
  chase('Chase rocket', Icons.center_focus_strong),
  orbit('Orbit field', Icons.threesixty),
  free('Free orbit', Icons.control_camera);

  final String label;
  final IconData icon;

  const FlightCameraMode(this.label, this.icon);
}

/// Everything a flight painter needs, rebuilt on every telemetry tick.
class FlightScene {
  /// GPS trail (east/up/south metres, oldest first).
  final List<Vector3> trail;
  final Vector3 rocketPos;

  /// `true` when [rocketPos] is a dead-reckoning estimate (GPS stale).
  final bool rocketIsDr;
  final double maxAlt;
  final double maxHoriz;
  final double pitchDeg;
  final double yawDeg;
  final double rollDeg;

  /// Airframe configuration from the FSM state: nosecone on / canopy open.
  final bool showNoseCone;
  final bool showParachute;
  final String? siteName;
  final String readout;

  const FlightScene({
    required this.trail,
    required this.rocketPos,
    required this.rocketIsDr,
    required this.maxAlt,
    required this.maxHoriz,
    required this.pitchDeg,
    required this.yawDeg,
    required this.rollDeg,
    required this.showNoseCone,
    required this.showParachute,
    required this.siteName,
    required this.readout,
  });
}

/// Pure lat/lon → world mapping (east/up/south metres around [lat0]/[lon0]).
/// Exposed for unit tests locking the handedness: east must be +X,
/// north must be −Z.
Vector3 worldFromLatLon(
  double lat,
  double lon,
  double agl,
  double lat0,
  double lon0,
  double cosLat0,
) =>
    Vector3(
      (lon - lon0) * metresPerDegreeLat * cosLat0,
      math.max(0.0, agl),
      -(lat - lat0) * metresPerDegreeLat,
    );

/// Position anchor of a scene (world origin + ground level).
class FlightAnchor {
  final double lat;
  final double lon;
  final double groundMsl;
  final double cosLat;

  FlightAnchor({required this.lat, required this.lon, required this.groundMsl})
      : cosLat = math.cos(radians(lat));
}

/// World origin for [state]: the configured launch site, else the first GPS
/// fix. `null` when neither exists yet. Shared by the scene builder and the
/// satellite imagery so both agree exactly.
FlightAnchor? flightAnchor(TelemetryState state, LaunchSite? site) {
  if (site != null) {
    return FlightAnchor(
      lat: site.latitude,
      lon: site.longitude,
      groundMsl: site.altitudeMsl,
    );
  }
  final history = state.history;
  for (var i = 0; i < history.length; i++) {
    final f = history.getChronological(i);
    if (f.gpsHasFix) {
      return FlightAnchor(
        lat: f.latitude,
        lon: f.longitude,
        groundMsl: f.gpsAltitude,
      );
    }
  }
  return null;
}

/// Builds the metric scene from the flight history: GPS trail, rocket
/// position, extents and readout. `null` when no position anchor exists yet
/// (frames arriving but no fix and no configured site).
FlightScene? buildFlightScene(TelemetryState state, LaunchSite? site) {
  final history = state.history;
  if (history.isEmpty) return null;
  final latest = state.latest!;

  final anchor = flightAnchor(state, site);
  if (anchor == null) return null;
  final lat0 = anchor.lat;
  final lon0 = anchor.lon;
  final groundMsl = anchor.groundMsl;
  final cosLat0 = anchor.cosLat;

  Vector3 enu(double lat, double lon, double agl) =>
      worldFromLatLon(lat, lon, agl, lat0, lon0, cosLat0);

  // Trail: GPS fixes only, decimated on absolute time buckets. Dead
  // reckoning is intentionally NOT part of the trail — when GPS is stale
  // the estimate is shown as a single violet point (see showDr).
  final spanMs =
      history[0].receivedAtMs - history.getChronological(0).receivedAtMs;
  final bucketMs = math.max(1, spanMs ~/ 400);
  final trail = <Vector3>[];
  var lastGpsBucket = -1;

  for (var i = 0; i < history.length; i++) {
    final f = history.getChronological(i);
    if (!f.gpsHasFix) continue;
    final bucket = f.receivedAtMs ~/ bucketMs;
    if (bucket == lastGpsBucket) continue;
    trail.add(enu(f.latitude, f.longitude, f.baroAltitude));
    lastGpsBucket = bucket;
  }

  // Current rocket position: GPS when available, dead reckoning otherwise.
  // Before the first fix (pad wait) the rocket sits on the pad — show it
  // there immediately instead of a blank "waiting" tile.
  // A silent link (no packets at all, e.g. disconnected radio) also falls
  // back to DR: the last frame still carries a fix, so staleness is judged
  // against the wall clock, exactly like the store's 1 Hz extrapolator.
  final drNow = state.replaying ? null : state.deadReckoning;
  final linkStale = drNow != null &&
      !state.replaying &&
      DateTime.now().millisecondsSinceEpoch - latest.receivedAtMs >
          TelemetryStore.drStaleMs;
  final showDr = drNow != null && (!latest.gpsHasFix || linkStale);
  Vector3 rocketPos;
  if (showDr) {
    rocketPos =
        enu(drNow.latitude, drNow.longitude, drNow.altitude - groundMsl);
  } else if (latest.gpsHasFix) {
    rocketPos = enu(latest.latitude, latest.longitude, latest.baroAltitude);
  } else if (trail.isNotEmpty) {
    rocketPos = trail.last;
  } else {
    rocketPos = enu(lat0, lon0, latest.baroAltitude);
  }

  var maxAlt = rocketPos.y;
  var maxHoriz =
      math.sqrt(rocketPos.x * rocketPos.x + rocketPos.z * rocketPos.z);
  for (final p in trail) {
    if (p.y > maxAlt) maxAlt = p.y;
    final h = math.sqrt(p.x * p.x + p.z * p.z);
    if (h > maxHoriz) maxHoriz = h;
  }
  final downrange =
      math.sqrt(rocketPos.x * rocketPos.x + rocketPos.z * rocketPos.z);

  return FlightScene(
    trail: trail,
    rocketPos: rocketPos,
    rocketIsDr: showDr,
    maxAlt: maxAlt,
    maxHoriz: maxHoriz,
    pitchDeg: latest.pitch,
    yawDeg: latest.yaw,
    rollDeg: latest.roll,
    showNoseCone: latest.fsmState.hasNosecone,
    showParachute: latest.fsmState.hasParachute,
    siteName: site?.name,
    readout: 'Alt ${rocketPos.y.toStringAsFixed(0)} m · '
        'Downrange ${downrange.toStringAsFixed(0)} m'
        '${showDr ? ' · DR' : ''}',
  );
}

// ── Camera ───────────────────────────────────────────────────────────────────

/// Computed camera for one frame.
class FlightCamera {
  final Matrix4 view;
  final Matrix4 vp;
  final Vector3 eye;
  final Vector3 target;
  final double dist;
  final Vector3 lightDir;

  const FlightCamera({
    required this.view,
    required this.vp,
    required this.eye,
    required this.target,
    required this.dist,
    required this.lightDir,
  });
}

FlightCamera computeFlightCamera({
  required FlightScene scene,
  required FlightCameraMode mode,
  required double azimuthDeg,
  required double elevationDeg,
  required double zoom,
  required double aspect,
}) {
  // Camera target/distance: on the rocket, or orbiting the whole field.
  final center = Vector3(0, scene.maxAlt * 0.45, 0);
  final sceneRadius = math.max(40.0, math.max(scene.maxHoriz, scene.maxAlt));
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
  // Capped below the degenerate straight-down view, where the camera basis
  // (and a map-style N-up/E-right reading of it) breaks down.
  final el = radians(elevationDeg.clamp(-15.0, 80.0));
  final camDir = Vector3(
    math.cos(el) * math.sin(az),
    math.sin(el),
    math.cos(el) * math.cos(az),
  );
  var eye = target + camDir * dist;
  if (eye.y < 2.0) eye = Vector3(eye.x, 2.0, eye.z);

  final proj = makePerspectiveMatrix(
      radians(50), aspect, 0.5, dist + sceneRadius * 4 + 120000);
  final view = makeViewMatrix(eye, target, Vector3(0, 1, 0));
  final vp = proj * view;

  // Headlight slightly above the camera, like the orientation viewer.
  final light = (camDir.clone()..scale(0.6)) + Vector3(-0.25, 0.8, 0.1);

  return FlightCamera(
    view: view,
    vp: vp,
    eye: eye,
    target: target,
    dist: dist,
    lightDir: light.normalized(),
  );
}

// ── Projection helpers ───────────────────────────────────────────────────────

/// Clip-space → NDC → pixel coordinates; `null` when at/behind the camera.
Offset? projectToScreen(Vector3 world, Matrix4 vp, Size size) {
  final clip = vp.transformed(Vector4(world.x, world.y, world.z, 1));
  if (clip.w <= 0.5) return null;
  final ndc = clip.xyz / clip.w;
  return Offset(
    (ndc.x * 0.5 + 0.5) * size.width,
    (0.5 - ndc.y * 0.5) * size.height,
  );
}

void drawWorldSegment(Canvas canvas, Vector3 a, Vector3 b, Matrix4 vp,
    Size size, Paint paint) {
  var ca = _clipOf(a, vp);
  var cb = _clipOf(b, vp);
  // Fully behind the camera: nothing to draw.
  if (ca.w <= _clipEps && cb.w <= _clipEps) return;
  // Partially behind: pull the outside end to the near-plane intersection
  // instead of dropping the whole line (receding lines used to vanish at
  // low camera angles).
  if (ca.w <= _clipEps) {
    ca = _clipNear(ca, cb);
  } else if (cb.w <= _clipEps) {
    cb = _clipNear(cb, ca);
  }
  canvas.drawLine(_divideClip(ca, size), _divideClip(cb, size), paint);
}

/// Near-plane guard matching [projectToScreen]'s cutoff.
const double _clipEps = 0.5;

Vector4 _clipOf(Vector3 world, Matrix4 vp) =>
    vp.transformed(Vector4(world.x, world.y, world.z, 1));

Offset _divideClip(Vector4 c, Size size) => Offset(
      (c.x / c.w * 0.5 + 0.5) * size.width,
      (0.5 - c.y / c.w * 0.5) * size.height,
    );

/// Intersection of segment out→inn with the w = [_clipEps] plane.
Vector4 _clipNear(Vector4 out, Vector4 inn) {
  final denom = inn.w - out.w;
  if (denom.abs() < 1e-12) return inn;
  final t = ((_clipEps - out.w) / denom).clamp(0.0, 1.0);
  return out * (1 - t) + inn * t;
}

/// Fills a world-space quad, clipped against the near plane (Sutherland–
/// Hodgman in clip space) so the ground keeps covering the view at low
/// camera angles instead of popping out.
void fillWorldQuad(
    Canvas canvas, List<Vector3> corners, Matrix4 vp, Size size, Paint paint) {
  final poly = [for (final c in corners) _clipOf(c, vp)];
  final clipped = <Vector4>[];
  for (var i = 0; i < poly.length; i++) {
    final cur = poly[i];
    final prev = poly[(i + poly.length - 1) % poly.length];
    final curIn = cur.w > _clipEps;
    final prevIn = prev.w > _clipEps;
    if (curIn) {
      if (!prevIn) clipped.add(_clipNear(prev, cur));
      clipped.add(cur);
    } else if (prevIn) {
      clipped.add(_clipNear(cur, prev));
    }
  }
  if (clipped.length < 3) return;
  final path = Path();
  for (var i = 0; i < clipped.length; i++) {
    final p = _divideClip(clipped[i], size);
    if (i == 0) {
      path.moveTo(p.dx, p.dy);
    } else {
      path.lineTo(p.dx, p.dy);
    }
  }
  path.close();
  canvas.drawPath(path, paint);
}

void drawGroundCircle(Canvas canvas, Vector3 center, double radius, Matrix4 vp,
    Size size, Paint paint) {
  final path = Path();
  var pen = false;
  for (var i = 0; i <= 32; i++) {
    final a = i * 2 * math.pi / 32;
    final s = projectToScreen(
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
double niceCeil(double v) {
  if (v <= 0) return 1;
  final mag =
      math.pow(10, (math.log(v) / math.ln10).floorToDouble()).toDouble();
  for (final m in const [1.0, 2.0, 5.0, 10.0]) {
    if (v <= m * mag) return m * mag;
  }
  return 10 * mag;
}

/// Ground grid extents for a scene (shared by the plain and textured ground
/// so the satellite patch can be sized to cover them).
({double half, double step}) flightGroundGrid(FlightScene scene) {
  final gridHalf = niceCeil(
      math.max(60.0, math.max(scene.maxHoriz * 1.3, scene.maxAlt * 0.6)));
  final step = niceCeil(gridHalf / 8);
  final n = (gridHalf / step).ceil();
  return (half: n * step, step: step);
}

// ── Shared painters ──────────────────────────────────────────────────────────

/// Procedural sky + far terrain ring, painted first so low camera angles meet
/// a horizon instead of the card void. Palette-relative, so dark mode gets a
/// night sky for free. (A photo skybox can replace the gradient later — the
/// call sits in one place per painter.)
///
/// The far ring is deliberately huge (past the horizon from any flight
/// camera) and sits a hair below the detailed plane so the near ground
/// overdraws it with no z-fighting shimmer; it is tinted from [groundTint]
/// (the satellite patch's mean color) lightly hazed toward the sky, so the
/// seam reads as aerial perspective instead of a grey card. A subtle
/// horizon-anchored haze band melts its top edge into the sky.
void paintSkyAndFarTerrain(Canvas canvas, Size size, FlightCamera cam,
    {Color? groundTint}) {
  final vp = cam.vp;
  final dark = AppThemeMode.instance.value;
  final zenith = dark
      ? const Color(0xFF0A0E1E)
      : const Color(0xFF7FA8D9);
  final mid = dark
      ? const Color(0xFF232B4A)
      : const Color(0xFFB4C9E4);
  final horizonSky = dark
      ? const Color(0xFF3D3A4D)
      : const Color(0xFFE9E6EC);
  canvas.drawRect(
    Offset.zero & size,
    Paint()
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: const Alignment(0, 0.9),
        colors: [zenith, mid, horizonSky],
        stops: const [0.0, 0.55, 0.85],
      ).createShader(Offset.zero & size),
  );
  // Far ground picks up the local landscape; the haze pull toward the sky
  // keeps it luminous at the horizon without washing it grey up close.
  final neutral = dark
      ? const Color(0xFF2A2E2A)
      : const Color(0xFFB7BCAE);
  final tint = groundTint ?? neutral;
  final farBase = dark
      ? Color.lerp(tint, Colors.black, 0.55)!
      : Color.lerp(tint, horizonSky, 0.22)!;
  const farHalf = 45000.0;
  const farY = -1.5;
  fillWorldQuad(
    canvas,
    [
      Vector3(-farHalf, farY, -farHalf),
      Vector3(farHalf, farY, -farHalf),
      Vector3(farHalf, farY, farHalf),
      Vector3(-farHalf, farY, farHalf),
    ],
    vp,
    size,
    Paint()..color = farBase,
  );
  // Aerial-perspective haze straddling the horizon so the far ring melts
  // into the sky. Drawn before the detailed ground, which overdraws the
  // lower part and keeps only the far blend.
  final horizonY = _horizonScreenY(cam, size);
  if (horizonY != null && horizonY > -300 && horizonY < size.height + 300) {
    const bandAbove = 24.0;
    const bandBelow = 150.0;
    final top = horizonY - bandAbove;
    canvas.drawRect(
      Rect.fromLTWH(0, top, size.width, bandAbove + bandBelow),
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            horizonSky.withValues(alpha: 0.55),
            horizonSky.withValues(alpha: 0.0),
          ],
        ).createShader(
            Rect.fromLTWH(0, top, size.width, bandAbove + bandBelow)),
    );
  }
}

/// Screen Y of the horizon (eye-height plane at distance), or `null` when
/// the camera looks straight down and there is no horizon on screen.
double? _horizonScreenY(FlightCamera cam, Size size) {
  final fwd = cam.target - cam.eye;
  fwd.y = 0;
  if (fwd.length < 1e-6) return null;
  fwd.normalize();
  final far = cam.eye + fwd * 30000;
  // Same height as the eye: converges to the horizon line at distance.
  far.y = cam.eye.y;
  final clip = cam.vp.transformed(Vector4(far.x, far.y, far.z, 1));
  if (clip.w <= _clipEps) return null;
  final iw = 1 / clip.w;
  return (0.5 - clip.y * iw * 0.5) * size.height;
}

/// GPS trail (solid blue). DR is never part of the trail.
void paintFlightTrail(
    Canvas canvas, FlightScene scene, Matrix4 vp, Size size) {
  final gpsPaint = Paint()
    ..color = AppColors.seriesGpsTrack.withValues(alpha: 0.85)
    ..style = PaintingStyle.stroke
    ..strokeWidth = 2.2
    ..strokeCap = StrokeCap.round
    ..strokeJoin = StrokeJoin.round;
  for (var i = 1; i < scene.trail.length; i++) {
    drawWorldSegment(canvas, scene.trail[i - 1], scene.trail[i], vp, size, gpsPaint);
  }
}

/// Drop line rocket→ground plus the violet DR ring when dead-reckoned.
void paintDropLineAndDr(
    Canvas canvas, FlightScene scene, Matrix4 vp, Size size) {
  drawWorldSegment(
    canvas,
    scene.rocketPos,
    Vector3(scene.rocketPos.x, 0, scene.rocketPos.z),
    vp,
    size,
    Paint()
      ..color = AppColors.mutedForeground.withValues(alpha: 0.45)
      ..strokeWidth = 1,
  );
  if (scene.rocketIsDr) {
    final s = projectToScreen(scene.rocketPos, vp, size);
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
}

/// Rocket mesh at [rocketPos] with the shared attitude. [baseLift] (in model
/// units, [RocketMesh.baseExtent] = lowest fin point) raises the mesh so its
/// base — not its middle — sits at the position: the flight views stand the
/// rocket on the ground instead of sinking its tail through the plane. The
/// attitude viewer passes 0 to keep rotating about the centre.
///
/// [showNoseCone] hides the popped cone; [showParachute] hangs the canopy
/// world-up from the body top: the attach point follows the (possibly
/// tilted) airframe, but the chute itself never tilts.
void paintRocketMesh(
  Canvas canvas,
  Size size,
  Matrix4 vp,
  Matrix4 view,
  Vector3 lightDir, {
  required Vector3 rocketPos,
  required double pitchDeg,
  required double yawDeg,
  required double rollDeg,
  required double scale,
  double baseLift = 0.0,
  bool showNoseCone = true,
  bool showParachute = false,
}) {
  final orientation = RocketMesh.orientationMatrix(
    pitchDeg: pitchDeg,
    yawDeg: yawDeg,
    rollDeg: rollDeg,
    scale: scale,
  );
  final model = Matrix4.translation(rocketPos) *
      orientation *
      Matrix4.translation(Vector3(0, baseLift, 0));

  // Parachute frame: translated to the body-top attach point, uniformly
  // scaled, but never rotated — the canopy always hangs straight up.
  final chuteModel = Matrix4.translation(
          model.transformed3(Vector3(0, RocketMesh.bodyTop, 0)))
      ..scaleByDouble(scale, scale, scale, 1.0);

  final visible = <_PaintTri>[];
  var index = 0;

  void push(RocketMeshTri tri, Matrix4 m, Vector3 worldNormal) {
    final a = m.transformed3(tri.a);
    final b = m.transformed3(tri.b);
    final c = m.transformed3(tri.c);

    final screenA = projectToScreen(a, vp, size);
    final screenB = projectToScreen(b, vp, size);
    final screenC = projectToScreen(c, vp, size);
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

    final za = view.transformed3(a).z;
    final zb = view.transformed3(b).z;
    final zc = view.transformed3(c).z;

    visible.add(_PaintTri(
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
    // Normals rotate with the orientation (no translation, no base lift —
    // the lift runs along the long axis and must not leak into lighting).
    push(tri, model, orientation.transformed3(tri.normal).normalized());
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

class _PaintTri {
  final Offset a, b, c;
  final double depth;

  /// Mesh order — stabilises the sort when coplanar faces tie on depth.
  final int order;
  final double brightness;
  final Color base;

  const _PaintTri(this.a, this.b, this.c,
      {required this.depth,
      required this.order,
      required this.brightness,
      required this.base});
}

/// Plain ground: subtle fill + 1-2-5 grid + projected N (−Z, blue) / E (+X,
/// amber) labels that rotate with the view.
void paintGroundPlain(
    Canvas canvas, FlightScene scene, Matrix4 vp, Size size) {
  final grid = flightGroundGrid(scene);
  final half = grid.half;
  final step = grid.step;
  final n = (half / step).ceil();

  final c0 = Vector3(-half, 0, -half);
  final c1 = Vector3(half, 0, -half);
  final c2 = Vector3(half, 0, half);
  final c3 = Vector3(-half, 0, half);
  // Subtle ground fill (near-plane clipped, survives low camera angles).
  fillWorldQuad(
    canvas,
    [c0, c1, c2, c3],
    vp,
    size,
    Paint()..color = AppColors.muted.withValues(alpha: 0.65),
  );

  final gridLine = Paint()
    ..color = AppColors.border
    ..strokeWidth = 1;
  final axisLine = Paint()
    ..color = AppColors.strongBorder
    ..strokeWidth = 1.4;
  for (var k = -n; k <= n; k++) {
    final off = k * step;
    final paint = k == 0 ? axisLine : gridLine;
    drawWorldSegment(canvas, Vector3(off, 0, -half), Vector3(off, 0, half), vp,
        size, paint);
    drawWorldSegment(canvas, Vector3(-half, 0, off), Vector3(half, 0, off), vp,
        size, paint);
  }

  paintGroundLabels(canvas, vp, size, half: half, step: step);
}

void paintGroundLabel(Canvas canvas, Matrix4 vp, Size size, Vector3 world,
    String label, Color color) {
  final pos = projectToScreen(world, vp, size);
  if (pos == null) return;
  final tp = TextPainter(
    text: TextSpan(
      text: label,
      style: AppText.microLabel.copyWith(
        fontSize: 10,
        letterSpacing: 1,
        color: color,
      ),
    ),
    textDirection: TextDirection.ltr,
  )..layout();
  tp.paint(canvas, pos + const Offset(-4, -8));
}

/// Cardinal ground labels — north sits on −Z (world Z is south).
void paintGroundLabels(Canvas canvas, Matrix4 vp, Size size,
    {required double half, required double step}) {
  paintGroundLabel(canvas, vp, size, Vector3(half + step * 0.3, 0, 0), 'E',
      AppColors.warning);
  paintGroundLabel(canvas, vp, size, Vector3(0, 0, -(half + step * 0.3)), 'N',
      AppColors.info);
}

void paintLaunchSite(
    Canvas canvas, FlightScene scene, Matrix4 vp, Size size) {
  // Flag pole with a small pennant.
  drawWorldSegment(
    canvas,
    Vector3.zero(),
    Vector3(0, 10, 0),
    vp,
    size,
    Paint()
      ..color = AppColors.pinkDeep
      ..strokeWidth = 1.6,
  );
  final tip = projectToScreen(Vector3(0, 10, 0), vp, size);
  final tail = projectToScreen(Vector3(0, 7.5, 0), vp, size);
  final point = projectToScreen(Vector3(2.6, 8.75, 0), vp, size);
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
  drawGroundCircle(
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

  final labelPos = projectToScreen(Vector3(0, 13, 0), vp, size);
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

/// Corner compass: North (−Z) / East (+X) / Up (+Y), projected with the live
/// camera rotation, so the gizmo and the ground labels always agree.
void paintCompass(Canvas canvas, Size size, Matrix4 view) {
  final origin = Offset(34, size.height - 38);
  const len = 26.0;
  const eyeDist = 3.0;

  final r = view.getRow(0).xyz;
  final u = view.getRow(1).xyz;
  final b = view.getRow(2).xyz;

  ({Offset offset, double toward}) project(Vector3 dirRaw) {
    final d = dirRaw.normalized();
    final vx = d.dot(r);
    final vy = d.dot(u);
    final vz = d.dot(b);
    final s = len * eyeDist / math.max(0.8, eyeDist - vz);
    return (offset: Offset(vx * s, -vy * s), toward: vz);
  }

  final axes = <(Color, String, ({Offset offset, double toward}))>[
    (AppColors.warning, 'E', project(Vector3(1, 0, 0))),
    (AppColors.success, 'U', project(Vector3(0, 1, 0))),
    (AppColors.info, 'N', project(Vector3(0, 0, -1))),
  ]..sort((x, y) => x.$3.toward.compareTo(y.$3.toward));

  for (final (color, label, projected) in axes) {
    final end = origin + projected.offset;
    final alpha = projected.toward < -0.15 ? 0.35 : 1.0;
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
          fontSize: 9,
          fontWeight: FontWeight.w700,
          color: lineColor,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, end + const Offset(2, -10));
  }
}
