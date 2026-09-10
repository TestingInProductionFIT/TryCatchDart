import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/replay_controller.dart';
import '../../state/telemetry_store.dart';
import '../components/waiting_for_data.dart';
import './shared/flight_3d_common.dart';
import './shared/flight_3d_shell.dart';
import './shared/orbit_camera.dart';
import './shared/rocket_mesh.dart';
import './shared/satellite_ground.dart';
import './shared/tile_io.dart';

/// 3D flight path over satellite imagery: the same scene, cameras and rocket
/// as [Flight3dTile], but the ground plane is textured with Esri World
/// Imagery around the launch site (the "Google Earth" view). Offline or
/// while tiles load it falls back to the plain ground.
///
/// Imagery is fetched per ground-grid size and cached; as the flight grows
/// past the current patch a larger one loads in the background while the old
/// image keeps showing.
class Flight3dSatelliteTile extends ConsumerStatefulWidget {
  const Flight3dSatelliteTile({super.key});

  @override
  ConsumerState<Flight3dSatelliteTile> createState() =>
      _Flight3dSatelliteWidgetState();
}

class _Flight3dSatelliteWidgetState
    extends ConsumerState<Flight3dSatelliteTile>
    with Flight3dShellState {
  /// Currently displayed patch (kept across growth-triggered reloads).
  SatellitePatch? _patch;

  /// Imagery request already in flight, to size growth.
  String? _requestedKey;

  /// Last imagery attempt (wall clock ms). While imageless, failed attempts
  /// back off so a dead network doesn't refire the tile burst every frame.
  int _lastPatchAttemptMs = 0;

  void _ensurePatch(FlightAnchor anchor, double halfMeters) {
    // Never render less than ~5 km² of context, however small the flight.
    final want = math.max(halfMeters, satMinHalfMeters);
    final key =
        '${anchor.lat.toStringAsFixed(4)},${anchor.lon.toStringAsFixed(4)},${want.toStringAsFixed(0)}';
    if (key == _requestedKey) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    // While imageless, back off after a failed attempt instead of refiring
    // the tile burst on every telemetry tick.
    if (_patch == null && now - _lastPatchAttemptMs < 15000) return;
    _requestedKey = key;
    _lastPatchAttemptMs = now;
    fetchSatellitePatch(
      lat: anchor.lat,
      lon: anchor.lon,
      halfMeters: want,
    ).then((patch) {
      if (!mounted) return;
      // Drop stale arrivals (a newer size was requested meanwhile).
      if (_requestedKey != key) return;
      if (patch == null) {
        // Let a later build retry (subject to the backoff above).
        _requestedKey = null;
        return;
      }
      setState(() => _patch = patch);
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
    final anchor = flightAnchor(state, site);
    if (scene == null || anchor == null) {
      return Center(child: WaitingForData());
    }
    _ensurePatch(anchor, flightGroundGrid(scene).half);

    return Flight3dShell(
      painter: _SatFlightPainter(
        scene: scene,
        mode: mode,
        azimuthDeg: camera.azimuthDeg,
        elevationDeg: camera.elevationDeg,
        zoom: zoom,
        patch: _patch,
        anchor: anchor,
      ),
      mode: mode,
      onMode: setShellMode,
      onZoomBy: zoomBy,
      onResetZoom: resetZoom,
      onOrbit: orbitBy,
      extraOverlays: [
        if (_patch != null)
          Positioned(
            right: 4,
            bottom: 2,
            child: Text(
              satelliteAttribution,
              style: TextStyle(
                fontSize: 9,
                color: Colors.black.withValues(alpha: 0.45),
              ),
            ),
          ),
      ],
    );
  }
}

// ── Renderer ─────────────────────────────────────────────────────────────────

class _SatFlightPainter extends CustomPainter {
  final FlightScene scene;
  final FlightCameraMode mode;
  final double azimuthDeg;
  final double elevationDeg;
  final double zoom;
  final SatellitePatch? patch;
  final FlightAnchor anchor;

  static const double _rocketScale = 3.5;

  _SatFlightPainter({
    required this.scene,
    required this.mode,
    required this.azimuthDeg,
    required this.elevationDeg,
    required this.zoom,
    required this.patch,
    required this.anchor,
  });

  @override
  void paint(Canvas canvas, Size size) {
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
    final grid = flightGroundGrid(scene);
    // Always render at least ~5 km² of imagery, however small the flight.
    final satHalf = math.max(grid.half, satMinHalfMeters);
    final satStep = niceCeil(satHalf / 8);

    paintSkyAndFarTerrain(canvas, size, cam, groundTint: patch?.averageColor);
    if (patch != null) {
      _paintTexturedGround(canvas, size, cam, satHalf, satStep);
    } else {
      paintGroundPlain(canvas, scene, cam.vp, size);
    }
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
      baseLift: RocketMesh.baseExtent,
      // Airframe configuration comes from the FSM state (cone pops at
      // apogee, canopy opens under parachute).
      showNoseCone: scene.showNoseCone,
      showParachute: scene.showParachute,
    );
    paintCompass(canvas, size, cam.view);
  }

  /// Drapes the satellite patch as a screen-space mesh: one node per ~21 px,
  /// each ray-cast onto the ground plane for exact UVs. Triangles are small
  /// on screen BY CONSTRUCTION, so affine UV interpolation cannot twist no
  /// matter how close or grazing the camera gets — world-space subdivision
  /// can never promise that, since cells near the camera project huge
  /// (that was the close-to-ground twisting: exact corner UVs, wrong
  /// interiors — the classic missing-perspective-correction look).
  ///
  /// Nodes whose ray misses the plane (sky) or lands outside the patch (far
  /// terrain shows through) subdivide to pin the boundary, then drop, so
  /// nothing can smear into the sky either. Single path every frame, so
  /// there is nothing to flap between. This deliberately avoids
  /// `Canvas.transform` with a perspective matrix, which silently paints
  /// nothing on Impeller/OpenGLES. Cardinal labels stay; the imagery needs
  /// no grid lines.
  void _paintTexturedGround(
      Canvas canvas, Size size, FlightCamera cam, double half, double step) {
    final patch = this.patch!;
    final img = patch.image;
    final w = img.width.toDouble();
    final h = img.height.toDouble();

    final invVp = cam.vp.clone()..invert();
    final s = (math.min(size.width, size.height) / 28).clamp(16.0, 48.0);
    const maxDepth = 3;
    const sub = 1 << maxDepth;
    final stepFine = s / sub;

    // Mesh nodes on the finest lattice, shared between neighbours.
    final nodes = <(int, int), _GroundNode?>{};
    _GroundNode? nodeAt(int fx, int fy) {
      final key = (fx, fy);
      if (nodes.containsKey(key)) return nodes[key];
      _GroundNode? node;
      final sx = fx * stepFine;
      final sy = fy * stepFine;
      final hit = rayGroundHit(
        invVp: invVp,
        eye: cam.eye,
        sx: sx,
        sy: sy,
        viewW: size.width,
        viewH: size.height,
      );
      if (hit != null) {
        final (:u, :v) = satUvFraction(
          hit.x,
          hit.z,
          anchor.lat,
          anchor.lon,
          anchor.cosLat,
          northLat: patch.northLat,
          southLat: patch.southLat,
          westLon: patch.westLon,
          eastLon: patch.eastLon,
        );
        if (u >= 0 && u <= 1 && v >= 0 && v <= 1) {
          node = _GroundNode(Offset(sx, sy), Offset(u * w, v * h));
        }
      }
      nodes[key] = node;
      return node;
    }

    final positions = <Offset>[];
    final uvs = <Offset>[];
    void emitTri(_GroundNode a, _GroundNode b, _GroundNode c) {
      positions.add(a.screen);
      uvs.add(a.uv);
      positions.add(b.screen);
      uvs.add(b.uv);
      positions.add(c.screen);
      uvs.add(c.uv);
    }

    void emitCell(int fx0, int fy0, int span, int depth) {
      final a = nodeAt(fx0, fy0);
      final b = nodeAt(fx0 + span, fy0);
      final c = nodeAt(fx0 + span, fy0 + span);
      final d = nodeAt(fx0, fy0 + span);
      if (a != null && b != null && c != null && d != null) {
        emitTri(a, b, c);
        emitTri(a, c, d);
        return;
      }
      if (depth >= maxDepth) {
        // Boundary cell at finest resolution — drop it so the sky or
        // the far terrain behind shows through instead of a clamped streak.
        return;
      }
      if (a == null && b == null && c == null && d == null) {
        // Fully empty cell (sky, or ground outside the patch): subdividing
        // blindly to the finest level burns ~80 ray-casts to draw nothing —
        // exactly what janks low horizontal cameras, where most of the
        // screen misses. Boundaries project to straight lines, which cannot
        // cross a quad without taking a corner, so an all-null cell hides a
        // boundary only when the valid island is smaller than the cell
        // itself; one centre probe catches that case.
        final halfSpan = span ~/ 2;
        if (halfSpan < 1) return;
        if (nodeAt(fx0 + halfSpan, fy0 + halfSpan) == null) return;
      }
      final halfSpan = span ~/ 2;
      emitCell(fx0, fy0, halfSpan, depth + 1);
      emitCell(fx0 + halfSpan, fy0, halfSpan, depth + 1);
      emitCell(fx0, fy0 + halfSpan, halfSpan, depth + 1);
      emitCell(fx0 + halfSpan, fy0 + halfSpan, halfSpan, depth + 1);
    }

    final cols = (size.width / s).ceil();
    final rows = (size.height / s).ceil();
    for (var j = 0; j < rows; j++) {
      for (var i = 0; i < cols; i++) {
        emitCell(i * sub, j * sub, sub, 0);
      }
    }

    if (positions.isEmpty) {
      // Nothing valid (e.g. staring at the sky) — plain fallback keeps
      // something up.
      paintGroundPlain(canvas, scene, cam.vp, size);
      return;
    }
    final paint = Paint()
      ..shader = ui.ImageShader(
        img,
        ui.TileMode.clamp,
        ui.TileMode.clamp,
        Matrix4.identity().storage,
      );
    canvas.drawVertices(
      ui.Vertices(
        ui.VertexMode.triangles,
        positions,
        textureCoordinates: uvs,
        colors: List.filled(positions.length, const Color(0xFFFFFFFF)),
      ),
      ui.BlendMode.modulate,
      paint,
    );

    paintGroundLabels(canvas, cam.vp, size, half: half, step: step);
  }

  @override
  bool shouldRepaint(covariant _SatFlightPainter old) =>
      !identical(old.scene, scene) ||
      old.mode != mode ||
      old.azimuthDeg != azimuthDeg ||
      old.elevationDeg != elevationDeg ||
      old.zoom != zoom ||
      old.patch != patch ||
      old.anchor != anchor;
}

/// One screen-space drape node: where it is on screen and what imagery
/// pixel it shows. See [_SatFlightPainter._paintTexturedGround].
class _GroundNode {
  final Offset screen;
  final Offset uv;

  const _GroundNode(this.screen, this.uv);
}
