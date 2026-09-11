import 'dart:math' as math;

import 'package:flutter/material.dart';
// `Colors` collides with material's — material's wins here.
import 'package:vector_math/vector_math_64.dart' hide Colors;
import 'package:serial/serial.dart';

import '../../../state/launch_site_store.dart';
import '../../../core/geo.dart';
import '../../../state/telemetry_store.dart';
import '../../../theme/app_colors.dart';
import './rocket_mesh.dart';

/// Shared scene, camera and painter helpers for the 3D flight views (plain
/// and satellite). Both tiles render the same [FlightScene] with the same
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
  pad('Launch pad', Icons.rocket_launch),
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

/// Fixed trail time bucket (ms): GPS fixes decimate on absolute buckets so
/// sampled points never move as history grows. (A span-derived bucket
/// resampled the whole trail every tick and the line visibly crawled.)
const int flightTrailBucketMs = 100;

/// Maximum trail points per scene; longer trails stride from the end via
/// [capTrailPoints] so the tip stays exact.
const int flightTrailMaxPoints = 400;

/// Caps a chronological point list to about [maxPoints], striding from the
/// END so the tip is always exact and the start is always kept. Pure —
/// unit-tested.
List<Vector3> capTrailPoints(List<Vector3> points,
    {int maxPoints = flightTrailMaxPoints}) {
  if (points.length <= maxPoints) return points;
  final stride = (points.length / maxPoints).ceil();
  final rev = <Vector3>[];
  var first = points.length - 1;
  for (var i = points.length - 1; i >= 0; i -= stride) {
    rev.add(points[i]);
    first = i;
  }
  final out = rev.reversed.toList();
  if (first != 0) out.insert(0, points[0]);
  // Prepending the start can push the count one over budget; drop the
  // second point (start, order and tip stay exact).
  if (out.length > maxPoints) out.removeAt(1);
  return out;
}

/// Builds the metric scene from the flight history: GPS trail, rocket
/// position, extents and readout. `null` when no position anchor exists yet
/// (frames arriving but no fix and no configured site).
///
/// This is the live path and always renders raw frames. Replays use
/// [buildReplayScene], which can smooth over the whole recording.
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

  // Trail: GPS fixes only, decimated on FIXED absolute time buckets so
  // points never move as history grows, then capped from the end so the
  // tip stays exact. Dead reckoning is intentionally NOT part of the
  // trail — when GPS is stale the estimate is shown as a single violet
  // point (see showDr).
  final all = <Vector3>[];
  var lastGpsBucket = -1;

  for (var i = 0; i < history.length; i++) {
    final f = history.getChronological(i);
    if (!f.gpsHasFix) continue;
    final bucket = f.receivedAtMs ~/ flightTrailBucketMs;
    if (bucket == lastGpsBucket) continue;
    all.add(enu(f.latitude, f.longitude, f.baroAltitude));
    lastGpsBucket = bucket;
  }
  final trail = capTrailPoints(all);

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
    showParachute: latest.fsmState.showsParachute,
    siteName: site?.name,
  );
}

/// Replay scene built from a recording's full pre-decoded frames.
///
/// Unlike [buildFlightScene] (bounded live ring, raw), the whole flight is
/// addressable here, so with [smoothingEnabled] the trail AND the rocket
/// position share one centered moving average with full lookahead — exactly
/// like the legacy web visualizer — and the rocket always sits on the trail
/// tip instead of teleporting ahead of a lagging line. Raw frames are
/// smoothed first and decimated after: decimating first aliases the GPS
/// quantization grid (1e-5 deg ≈ 1.1 m) into visible wiggles no post-hoc
/// average can remove. Altitude stays raw in both modes; the recorded
/// frames, charts and map are unaffected (always raw).
FlightScene? buildReplayScene({
  required List<TelemetryFrame> frames,
  required int positionMs,
  required LaunchSite? site,
  bool smoothingEnabled = false,
}) {
  if (frames.isEmpty) return null;
  final t0 = frames.first.receivedAtMs;
  var lo = 0;
  var hi = frames.length;
  while (lo < hi) {
    final mid = (lo + hi) >> 1;
    if (frames[mid].receivedAtMs - t0 <= positionMs) {
      lo = mid + 1;
    } else {
      hi = mid;
    }
  }
  var idx = lo - 1;
  if (idx < 0) idx = 0;
  if (idx > frames.length - 1) idx = frames.length - 1;

  // Anchor: file site, else the first GPS fix in the recording.
  late final double lat0;
  late final double lon0;
  if (site != null) {
    lat0 = site.latitude;
    lon0 = site.longitude;
  } else {
    TelemetryFrame? fix;
    for (final f in frames) {
      if (f.gpsHasFix) {
        fix = f;
        break;
      }
    }
    if (fix == null) return null;
    lat0 = fix.latitude;
    lon0 = fix.longitude;
  }
  final cosLat0 = math.cos(radians(lat0));

  Vector3 worldOf(TelemetryFrame f) => worldFromLatLon(
        f.latitude,
        f.longitude,
        f.baroAltitude,
        lat0,
        lon0,
        cosLat0,
      );

  // Fix-only subsequence (matches the live builder: the trail is GPS).
  final fixIdx = <int>[];
  for (var i = 0; i < frames.length; i++) {
    if (frames[i].gpsHasFix) fixIdx.add(i);
  }
  // Tip: last fix at or before the playhead.
  lo = 0;
  hi = fixIdx.length;
  while (lo < hi) {
    final mid = (lo + hi) >> 1;
    if (fixIdx[mid] <= idx) {
      lo = mid + 1;
    } else {
      hi = mid;
    }
  }
  final tip = lo - 1;
  final tipFrame = frames[idx];

  if (tip < 0) {
    // No fix yet: the rocket waits on the pad like in the live builder.
    final pad =
        worldFromLatLon(lat0, lon0, tipFrame.baroAltitude, lat0, lon0, cosLat0);
    final padAttitude = replayAttitude(
      frames: frames,
      positionMs: positionMs,
      smoothingEnabled: smoothingEnabled,
    );
    return FlightScene(
      trail: const [],
      rocketPos: pad,
      rocketIsDr: false,
      maxAlt: pad.y,
      maxHoriz: 0,
      pitchDeg: padAttitude.pitchDeg,
      yawDeg: padAttitude.yawDeg,
      rollDeg: padAttitude.rollDeg,
      showNoseCone: tipFrame.fsmState.hasNosecone,
      showParachute: tipFrame.fsmState.showsParachute,
      siteName: site?.name,
    );
  }

  Vector3 rawAt(int k) => worldOf(frames[fixIdx[k]]);

  Vector3 smoothAt(int k) {
    // Centered ±35 over the fix subsequence, clamped to the FULL recording
    // (lookahead into not-yet-played frames — the legacy visualizer smoothed
    // its whole dataset the same way). Horizontal only; altitude stays raw.
    var a = k - replayTrailHalfWindow;
    var b = k + replayTrailHalfWindow;
    if (a < 0) a = 0;
    if (b > fixIdx.length - 1) b = fixIdx.length - 1;
    var sx = 0.0;
    var sz = 0.0;
    for (var j = a; j <= b; j++) {
      final p = rawAt(j);
      sx += p.x;
      sz += p.z;
    }
    final n = b - a + 1;
    return Vector3(sx / n, rawAt(k).y, sz / n);
  }

  // Decimate to a paintable point count via capTrailPoints: tip-exact,
  // start-kept, and stable as the playhead advances (the old tip-derived
  // stride resampled earlier points on every seek step).
  final rawTrail = <Vector3>[];
  for (var k = 0; k <= tip; k++) {
    rawTrail.add(smoothingEnabled ? smoothAt(k) : rawAt(k));
  }
  final trail = capTrailPoints(rawTrail);
  final tipPoint = trail.last;

  var maxAlt = tipPoint.y;
  var maxHoriz = math.sqrt(
      tipPoint.x * tipPoint.x + tipPoint.z * tipPoint.z);
  for (final p in trail) {
    if (p.y > maxAlt) maxAlt = p.y;
    final h = math.sqrt(p.x * p.x + p.z * p.z);
    if (h > maxHoriz) maxHoriz = h;
  }

  final attitude = replayAttitude(
    frames: frames,
    positionMs: positionMs,
    smoothingEnabled: smoothingEnabled,
  );
  final pitchDeg = attitude.pitchDeg;
  final yawDeg = attitude.yawDeg;
  final rollDeg = attitude.rollDeg;

  return FlightScene(
    trail: trail,
    // Same smoothing as the trail tip: the rocket can never disagree
    // with the line it sits on.
    rocketPos: tipPoint,
    rocketIsDr: false,
    maxAlt: maxAlt,
    maxHoriz: maxHoriz,
    pitchDeg: pitchDeg,
    yawDeg: yawDeg,
    rollDeg: rollDeg,
    showNoseCone: tipFrame.fsmState.hasNosecone,
    showParachute: tipFrame.fsmState.showsParachute,
    siteName: site?.name,
  );
}

/// Half-width of the centered trail average ([buildReplayScene]) and the
/// length of the trailing rotation average ([replayAttitude]).
const int replayTrailHalfWindow = 35;
const int replayAttitudeWindow = 35;

/// Replay rotation at [positionMs]: raw frame angles by default, or the
/// smoothed display attitude when [smoothingEnabled].
///
/// The smoothed path matches [buildReplayScene]: a trailing
/// [replayAttitudeWindow]-frame averaged specific-force vector via
/// [smoothedAttitude] with yaw forced to 0 (compass heading is unknown —
/// the legacy yaw was always 0). Shared by the flight views (via
/// [buildReplayScene]) and the orientation viewer so the toggle smooths
/// every rotating airframe, not just the trail views.
({double pitchDeg, double yawDeg, double rollDeg}) replayAttitude({
  required List<TelemetryFrame> frames,
  required int positionMs,
  required bool smoothingEnabled,
}) {
  final t0 = frames.first.receivedAtMs;
  var lo = 0;
  var hi = frames.length;
  while (lo < hi) {
    final mid = (lo + hi) >> 1;
    if (frames[mid].receivedAtMs - t0 <= positionMs) {
      lo = mid + 1;
    } else {
      hi = mid;
    }
  }
  var idx = lo - 1;
  if (idx < 0) idx = 0;
  if (idx > frames.length - 1) idx = frames.length - 1;
  if (!smoothingEnabled) {
    final f = frames[idx];
    return (pitchDeg: f.pitch, yawDeg: f.yaw, rollDeg: f.roll);
  }
  var from = idx - (replayAttitudeWindow - 1);
  if (from < 0) from = 0;
  final attitude = smoothedAttitude(frames.sublist(from, idx + 1),
      window: replayAttitudeWindow);
  return (
    pitchDeg: attitude.pitchDeg,
    yawDeg: 0.0,
    rollDeg: attitude.rollDeg,
  );
}

/// Display attitude from an averaged specific-force vector, using the same
/// tilt-from-accelerometer formula the legacy ground station applied per
/// packet. Averaging the vector (not the angles) keeps `atan2` stable when
/// the per-frame estimate swings — near free-fall at apogee, chute swing,
/// vibration — while still tracking real orientation changes. `frames` must
/// be chronological with the newest last; at most the trailing [window]
/// entries are used. Pure: safe to unit-test.
({double rollDeg, double pitchDeg}) smoothedAttitude(
  List<TelemetryFrame> frames, {
  int window = 25,
}) {
  if (frames.isEmpty) return (rollDeg: 0.0, pitchDeg: 0.0);
  final n = math.min(window, frames.length);
  var ax = 0.0;
  var ay = 0.0;
  var az = 0.0;
  for (var i = frames.length - n; i < frames.length; i++) {
    ax += frames[i].accelX;
    ay += frames[i].accelY;
    az += frames[i].accelZ;
  }
  ax /= n;
  ay /= n;
  az /= n;
  return (
    rollDeg: math.atan2(ay, az) * 180 / math.pi,
    pitchDeg: math.atan2(-ax, math.sqrt(ay * ay + az * az)) * 180 / math.pi,
  );
}

// ── Camera ───────────────────────────────────────────────────────────────────

/// Vertical field of view (radians) shared by the flight cameras.
const double flightFovY = 50 * math.pi / 180;

/// Computed camera for one frame.
class FlightCamera {
  final Matrix4 view;
  final Matrix4 vp;
  final Vector3 eye;
  final Vector3 target;
  final double dist;

  /// Vertical field of view (radians) and aspect ratio, so the satellite
  /// drape can build analytic ground rays without inverting [vp] per frame
  /// (the inverse jittered at grazing angles and read as terrain wobble).
  final double fovY;
  final double aspect;
  final Vector3 lightDir;

  const FlightCamera({
    required this.view,
    required this.vp,
    required this.eye,
    required this.target,
    required this.dist,
    required this.fovY,
    required this.aspect,
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
  // Camera target/distance. Chase keeps a constant standoff from the
  // rocket (it used to scale with the flight extents, so the camera drifted
  // away as the flight grew); orbit-field frames the whole scene; pad sits
  // by the launch rail and tracks the rocket like the legacy visualizer.
  final center = Vector3(0, scene.maxAlt * 0.45, 0);
  final sceneRadius = math.max(40.0, math.max(scene.maxHoriz, scene.maxAlt));
  final (Vector3 target, double dist) = switch (mode) {
    FlightCameraMode.chase => (scene.rocketPos, 7.0 / zoom),
    FlightCameraMode.pad => (scene.rocketPos, 0),
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
  if (mode == FlightCameraMode.pad) {
    // Fixed spectator spot by the pad, tracking the rocket.
    eye = Vector3(22, 3, 38) * (1 / zoom);
  }
  if (eye.y < 2.0) eye = Vector3(eye.x, 2.0, eye.z);

  // Headlight slightly above the camera, like the orientation viewer.
  final light = (camDir.clone()..scale(0.6)) + Vector3(-0.25, 0.8, 0.1);

  return flightCameraFromEyeTarget(
    eye: eye,
    target: target,
    dist: dist,
    fovY: flightFovY,
    aspect: aspect,
    lightDir: light.normalized(),
  );
}

/// Projection whose near/far hug the actual eye distance so it stays
/// well-conditioned: a fixed 0.5 m near against a ~120 km far made the
/// old inverse view-projection jitter at grazing angles. The far plane
/// still clears the 45 km far-terrain ring from any camera.
Matrix4 flightProjection({
  required double eyeDist,
  required double fovY,
  required double aspect,
}) {
  final near = (eyeDist * 0.02).clamp(0.05, 50.0);
  final far = eyeDist + 90000.0;
  return makePerspectiveMatrix(fovY, aspect, near, far);
}

/// Assembles a [FlightCamera] from an explicit eye/target pair (shared by
/// [computeFlightCamera] and [clampEyeAboveTerrain] so both agree exactly).
FlightCamera flightCameraFromEyeTarget({
  required Vector3 eye,
  required Vector3 target,
  required double dist,
  required double fovY,
  required double aspect,
  required Vector3 lightDir,
}) {
  final view = makeViewMatrix(eye, target, Vector3(0, 1, 0));
  final vp = flightProjection(
        eyeDist: eye.distanceTo(target),
        fovY: fovY,
        aspect: aspect,
      ) *
      view;
  return FlightCamera(
    view: view,
    vp: vp,
    eye: eye,
    target: target,
    dist: dist,
    fovY: fovY,
    aspect: aspect,
    lightDir: lightDir,
  );
}

/// Lifts a camera that ended up under the terrain surface back above it,
/// keeping the target (the clamped rocket) fixed. Without this, chase/pad
/// views dive underground whenever the raw target sits below a DEM hill —
/// the camera must follow the clamped rocket, not the reported one.
FlightCamera clampEyeAboveTerrain(FlightCamera cam, double minEyeY) {
  if (cam.eye.y >= minEyeY) return cam;
  return flightCameraFromEyeTarget(
    eye: Vector3(cam.eye.x, minEyeY, cam.eye.z),
    target: cam.target,
    dist: cam.dist,
    fovY: cam.fovY,
    aspect: cam.aspect,
    lightDir: cam.lightDir,
  );
}

// ── Projection helpers ───────────────────────────────────────────────────────

/// Clip-space → NDC → pixel coordinates; `null` when at/behind the camera.
Offset? projectToScreen(Vector3 world, Matrix4 vp, Size size) {
  final clip = vp.transformed(Vector4(world.x, world.y, world.z, 1));
  if (clip.w <= clipEps) return null;
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
  if (ca.w <= clipEps && cb.w <= clipEps) return;
  // Partially behind: pull the outside end to the near-plane intersection
  // instead of dropping the whole line (receding lines used to vanish at
  // low camera angles).
  if (ca.w <= clipEps) {
    ca = _clipNear(ca, cb);
  } else if (cb.w <= clipEps) {
    cb = _clipNear(cb, ca);
  }
  canvas.drawLine(_divideClip(ca, size), _divideClip(cb, size), paint);
}

/// Near-plane guard matching [projectToScreen]'s cutoff: any positive w is
/// in front of the camera and drawable. (A previous 0.5 m cutoff ate the
/// rocket mesh and ground cells close to the lens.)
const double clipEps = 1e-6;

Vector4 _clipOf(Vector3 world, Matrix4 vp) =>
    vp.transformed(Vector4(world.x, world.y, world.z, 1));

Offset _divideClip(Vector4 c, Size size) => Offset(
      (c.x / c.w * 0.5 + 0.5) * size.width,
      (0.5 - c.y / c.w * 0.5) * size.height,
    );

/// Intersection of segment out→inn with the w = [clipEps] plane.
Vector4 _clipNear(Vector4 out, Vector4 inn) {
  final denom = inn.w - out.w;
  if (denom.abs() < 1e-12) return inn;
  final t = ((clipEps - out.w) / denom).clamp(0.0, 1.0);
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
    final curIn = cur.w > clipEps;
    final prevIn = prev.w > clipEps;
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
///
/// Capped at 10 km half-side (20×20 km): the camera still frames flights
/// that drift further, but the detailed ground/imagery stops growing and
/// the far-terrain ring takes over behind it.
({double half, double step}) flightGroundGrid(FlightScene scene) {
  final gridHalf = math.min(
      10000.0,
      niceCeil(
          math.max(60.0, math.max(scene.maxHoriz * 1.3, scene.maxAlt * 0.6))));
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
/// (the satellite patch's mean color) lightly lifted toward the sky, so the
/// seam reads as distance instead of a grey card. Sky and ground meet
/// directly at the horizon — no haze band overlays (a banded overlay reads
/// as a separate stripe at low camera angles).
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
}

/// GPS trail (solid blue). DR is never part of the trail — when
/// [FlightScene.rocketIsDr] the trail stops at the last GPS fix and the
/// dead-reckoning leg is drawn separately as a violet dashed connector (see
/// [paintDropLineAndDr]). With [tipOverride] (and a GPS-locked rocket) the
/// last leg runs to the override (the CG-anchored, ground-clamped rocket
/// position) instead of the raw reported fix, so the trail meets the
/// rocket's middle.
void paintFlightTrail(
    Canvas canvas, FlightScene scene, Matrix4 vp, Size size,
    {Vector3? tipOverride}) {
  final gpsPaint = Paint()
    ..color = AppColors.seriesGpsTrack.withValues(alpha: 0.85)
    ..style = PaintingStyle.stroke
    ..strokeWidth = 2.2
    ..strokeCap = StrokeCap.round
    ..strokeJoin = StrokeJoin.round;
  for (var i = 1; i < scene.trail.length; i++) {
    drawWorldSegment(canvas, scene.trail[i - 1], scene.trail[i], vp, size, gpsPaint);
  }
  if (tipOverride != null && scene.trail.isNotEmpty && !scene.rocketIsDr) {
    final last = scene.trail.last;
    if ((tipOverride - last).length > 1e-6) {
      drawWorldSegment(canvas, last, tipOverride, vp, size, gpsPaint);
    }
  }
}

/// CG-anchored, ground-clamped rocket position for the flight views.
///
/// The mesh pivots about its CG ([RocketMesh.cgY]) so pitch/roll rotate the
/// airframe about its centre; the anchor is the reported position lifted
/// just enough to keep the tail (vertical) or belly (horizontal) out of the
/// ground surface. [groundY] is the terrain height under the rocket (0 on
/// the flat plain view); aloft the lift is zero and the trail meets the CG
/// exactly.
Vector3 cgAnchorPos({
  required Vector3 rocketPos,
  required double pitchDeg,
  required double yawDeg,
  required double scale,
  double groundY = 0.0,
}) {
  final orientation = RocketMesh.orientationMatrix(
    pitchDeg: pitchDeg,
    yawDeg: yawDeg,
    scale: 1.0,
  );
  final bodyAxis = orientation.transformed3(Vector3(0, 1, 0)).normalized();
  final tailOff = (RocketMesh.finBottom - RocketMesh.cgY) * scale;
  final noseOff = (RocketMesh.noseTip - RocketMesh.cgY) * scale;
  final radius = RocketMesh.bodyRadius * scale;
  final lowest = rocketPos.y +
      math.min(math.min(tailOff * bodyAxis.y, noseOff * bodyAxis.y), -radius);
  if (lowest >= groundY) return rocketPos;
  return rocketPos + Vector3(0, groundY - lowest, 0);
}

/// Screen-space dashed segment between two world points, clipped against
/// the near plane like [drawWorldSegment]. Pure screen-space dashing keeps
/// dash lengths uniform regardless of perspective depth.
void drawWorldDashedSegment(Canvas canvas, Vector3 a, Vector3 b, Matrix4 vp,
    Size size, Paint paint,
    {double dashPx = 6, double gapPx = 4}) {
  var ca = _clipOf(a, vp);
  var cb = _clipOf(b, vp);
  if (ca.w <= clipEps && cb.w <= clipEps) return;
  if (ca.w <= clipEps) {
    ca = _clipNear(ca, cb);
  } else if (cb.w <= clipEps) {
    cb = _clipNear(cb, ca);
  }
  final pa = _divideClip(ca, size);
  final pb = _divideClip(cb, size);
  final dx = pb.dx - pa.dx;
  final dy = pb.dy - pa.dy;
  final len = math.sqrt(dx * dx + dy * dy);
  if (len < 1e-6) return;
  final ux = dx / len;
  final uy = dy / len;
  var dist = 0.0;
  while (dist < len) {
    final end = math.min(dist + dashPx, len);
    canvas.drawLine(
      Offset(pa.dx + ux * dist, pa.dy + uy * dist),
      Offset(pa.dx + ux * end, pa.dy + uy * end),
      paint,
    );
    dist = end + gapPx;
  }
}

/// Drop line rocket→ground plus the violet DR marker when dead-reckoned:
/// a ring at the estimate and a dashed connector from the last known GPS
/// position ([FlightScene.trail].last) to the estimate, so the DR position
/// never leaves a solid trail.
/// With [anchorOverride] the line hangs from the CG anchor instead of the
/// raw reported fix. [groundY] is the terrain surface under the rocket
/// (0 on the flat plain view).
void paintDropLineAndDr(
    Canvas canvas, FlightScene scene, Matrix4 vp, Size size,
    {Vector3? anchorOverride, double groundY = 0.0}) {
  final top = anchorOverride ?? scene.rocketPos;
  drawWorldSegment(
    canvas,
    top,
    Vector3(top.x, groundY, top.z),
    vp,
    size,
    Paint()
      ..color = AppColors.mutedForeground.withValues(alpha: 0.45)
      ..strokeWidth = 1,
  );
  if (scene.rocketIsDr) {
    if (scene.trail.isNotEmpty) {
      final last = scene.trail.last;
      if ((top - last).length > 1e-6) {
        drawWorldDashedSegment(
          canvas,
          last,
          top,
          vp,
          size,
          Paint()
            ..color = AppColors.seriesDeadReckoning.withValues(alpha: 0.9)
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.6
            ..strokeCap = StrokeCap.round,
        );
      }
    }
    final s = projectToScreen(top, vp, size);
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

/// Formats a below-terrain depth for the rocket badge: one decimal under
/// 10 m, whole metres above. Pure — unit-tested.
String formatUnderMeters(double meters) {
  final m = meters.clamp(0.0, 99999.0);
  return m < 10
      ? '${m.toStringAsFixed(1)} m under ground'
      : '${m.round()} m under ground';
}

/// Cheap Minecraft-style shadow disk: a flat translucent ellipse on the
/// terrain surface under the rocket, so the eye can anchor the airframe to
/// the ground it is flying over. Skipped when the surface point is behind
/// the camera.
void paintShadowDisk(
    Canvas canvas, Matrix4 vp, Size size, Vector3 surfaceCenter, double radius,
    {double alpha = 0.30}) {
  final path = Path();
  var started = false;
  for (var i = 0; i <= 24; i++) {
    final a = i * 2 * math.pi / 24;
    final s = projectToScreen(
      surfaceCenter +
          Vector3(radius * math.cos(a), 0, radius * math.sin(a)),
      vp,
      size,
    );
    // Behind the camera (lens inside the disk): skip rather than smear.
    if (s == null) return;
    if (started) {
      path.lineTo(s.dx, s.dy);
    } else {
      path.moveTo(s.dx, s.dy);
      started = true;
    }
  }
  path.close();
  canvas.drawPath(
    path,
    Paint()..color = const Color(0xFF000000).withValues(alpha: alpha),
  );
}

/// "N m under ground" badge next to a terrain-clamped rocket. No-op when
/// the anchor projects behind the camera.
void paintUnderGroundLabel(
    Canvas canvas, Matrix4 vp, Size size, Vector3 anchorWorld, String text) {
  final pos = projectToScreen(anchorWorld, vp, size);
  if (pos == null) return;
  final tp = TextPainter(
    text: TextSpan(
      text: text,
      style: AppText.microLabel.copyWith(
        fontSize: 10,
        letterSpacing: 0.5,
        color: AppColors.warning,
        fontWeight: FontWeight.w700,
      ),
    ),
    textDirection: TextDirection.ltr,
  )..layout();
  tp.paint(canvas, pos + const Offset(12, -30));
}

/// Rocket mesh at [rocketPos] with the shared attitude. [baseLift] (in model
/// units) is the pre-rotation lift: the flight views pass `-RocketMesh.cgY`
/// so the mesh pivots about its CG (see [cgAnchorPos], which also keeps the
/// airframe out of the ground plane). The attitude viewer passes 0 to keep
/// rotating about the mesh origin (already ~the CG).
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
  // The flag marks a real configured/file launch site — never a fallback
  // origin (first fix). Without a site there is nothing to flag. Real-life
  // scale: 2 m pole, 2 m diameter ground circle.
  if (scene.siteName == null || scene.siteName!.isEmpty) return;
  drawWorldSegment(
    canvas,
    Vector3.zero(),
    Vector3(0, 2, 0),
    vp,
    size,
    Paint()
      ..color = AppColors.pinkDeep
      ..strokeWidth = 1.6,
  );
  final tip = projectToScreen(Vector3(0, 2, 0), vp, size);
  final tail = projectToScreen(Vector3(0, 1.5, 0), vp, size);
  final point = projectToScreen(Vector3(0.52, 1.75, 0), vp, size);
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
    1,
    vp,
    size,
    Paint()
      ..color = AppColors.pinkDeep.withValues(alpha: 0.55)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.4,
  );

  final labelPos = projectToScreen(Vector3(0, 2.6, 0), vp, size);
  if (labelPos == null) return;
  final tp = TextPainter(
    text: TextSpan(
      text: 'Launch site · ${scene.siteName}',
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
