import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_map/flutter_map.dart'
    show BuiltInMapCachingProvider;
import 'package:vector_math/vector_math_64.dart';

import '../../../core/geo.dart';
import '../../../theme/app_colors.dart';
import './tile_io.dart';

/// Bridges theme colors into `dart:ui` paint code.
ui.Color _uiColor(ui.Color c) => ui.Color(c.toARGB32());

/// Satellite imagery draped over the 3D flight views' ground plane.
///
/// Tiles come from the same Esri World Imagery source as the 2D map's
/// satellite layer (internet required); failures fall back to the plain
/// ground. Pure tile math is unit-tested; fetching/stitching is I/O.

// ── Pure slippy-map math (testable) ──────────────────────────────────────────

/// Longitude → tile X at [zoom].
int satTileX(double lon, int zoom) {
  final n = 1 << zoom;
  return (((lon + 180) / 360 * n).floor()).clamp(0, n - 1);
}

/// Latitude → tile Y at [zoom].
int satTileY(double lat, int zoom) {
  final n = 1 << zoom;
  final rad = lat * math.pi / 180;
  final y = ((1 - math.log(math.tan(rad) + 1 / math.cos(rad)) / math.pi) /
          2 *
          n)
      .floor();
  return y.clamp(0, n - 1);
}

/// West edge longitude of tile [x].
double satTileLonWest(int x, int zoom) => x / (1 << zoom) * 360 - 180;

/// North edge latitude of tile [y].
double satTileLatNorth(int y, int zoom) {
  final n = 1 << zoom;
  final latRad = math.atan(_sinh(math.pi * (1 - 2 * y / n)));
  return latRad * 180 / math.pi;
}

double _sinh(double x) => (math.exp(x) - math.exp(-x)) / 2;

/// Metres per pixel of Web-Mercator tiles at [zoom] and [lat].
double satMetresPerPixel(double lat, int zoom) =>
    156543.03392 * math.cos(lat * math.pi / 180) / (1 << zoom);

/// Zoom whose tiles cover [halfMeters] (half-extent) at roughly
/// [targetPixels] across (denser than the screen needs, so chase close-ups
/// stay sharp). Pure — unit-tested.
int satZoomForHalfMeters(double halfMeters, double lat,
    {int targetPixels = 1280}) {
  var zoom = (math.log(156543.03392 *
              math.cos(lat * math.pi / 180) *
              targetPixels /
              (halfMeters * 2)) /
          math.ln2)
      .round();
  // Esri serves up to 19 in covered areas; missing levels fall back to the
  // parent tile (see [_fetchTileImage]).
  return zoom.clamp(10, 19);
}

/// World (east/south metres around lat0/lon0) → UV fractions into the given
/// geo bounds. v=0 is the north edge (image row 0). Pure — unit-tested.
({double u, double v}) satUvFraction(
  double eastM,
  double southM,
  double lat0,
  double lon0,
  double cosLat0, {
  required double northLat,
  required double southLat,
  required double westLon,
  required double eastLon,
}) {
  final lon = lon0 + eastM / (metresPerDegreeLat * cosLat0);
  final lat = lat0 - southM / metresPerDegreeLat;
  final u = (lon - westLon) / (eastLon - westLon).clamp(1e-12, 360);
  final v =
      (northLat - lat) / (northLat - southLat).clamp(1e-12, 180);
  return (u: u, v: v);
}

// ── Perspective mapping (homography) ─────────────────────────────────────────

/// Minimum ground half-extent (m) the satellite view always renders:
/// 1120 m half-side ≈ 5 km² of context even for tiny flights.
const double satMinHalfMeters = 1120;

/// Solves the 2D projective transform mapping [src] (image pixels) onto
/// [dst] (screen pixels) from 4 corner correspondences, returned as the 8
/// free coefficients (h22 = 1). `null` when degenerate.
///
/// Screen-space UV interpolation is only affine per triangle, which smears
/// imagery at grazing angles — the ground plane instead gets one exact
/// projective draw via [homographyMatrix] + canvas.transform. Pure and
/// unit-tested.
List<double>? solveHomography(
  List<({double x, double y})> src,
  List<({double x, double y})> dst,
) {
  assert(src.length == 4 && dst.length == 4);
  // 8x8 system, h22 fixed to 1: each correspondence gives
  //   -u*h00 - v*h01 - h02 + x*u*h20 + x*v*h21 = -x   (and likewise for y).
  final a = List.generate(8, (_) => List.filled(9, 0.0));
  for (var i = 0; i < 4; i++) {
    final u = src[i].x, v = src[i].y;
    final x = dst[i].x, y = dst[i].y;
    a[2 * i] = [-u, -v, -1, 0, 0, 0, x * u, x * v, -x];
    a[2 * i + 1] = [0, 0, 0, -u, -v, -1, y * u, y * v, -y];
  }
  // Gaussian elimination with partial pivoting.
  for (var col = 0; col < 8; col++) {
    var pivot = col;
    var best = a[pivot][col].abs();
    for (var row = col + 1; row < 8; row++) {
      final v = a[row][col].abs();
      if (v > best) {
        best = v;
        pivot = row;
      }
    }
    if (best < 1e-12) return null;
    if (pivot != col) {
      final tmp = a[pivot];
      a[pivot] = a[col];
      a[col] = tmp;
    }
    final inv = 1 / a[col][col];
    for (var j = col; j < 9; j++) {
      a[col][j] *= inv;
    }
    for (var row = 0; row < 8; row++) {
      if (row == col) continue;
      final f = a[row][col];
      if (f == 0) continue;
      for (var j = col; j < 9; j++) {
        a[row][j] -= f * a[col][j];
      }
    }
  }
  return [for (var i = 0; i < 8; i++) a[i][8]];
}

/// Embeds 2D homography coefficients into a 4x4 column-major matrix for
/// [Canvas.transform]: screen = H * uv with perspective divide.
List<double> homographyMatrix(List<double> h) {
  assert(h.length == 8);
  final h00 = h[0], h01 = h[1], h02 = h[2];
  final h10 = h[3], h11 = h[4], h12 = h[5];
  final h20 = h[6], h21 = h[7];
  return [
    h00, h10, 0, h20, //
    h01, h11, 0, h21, //
    0, 0, 1, 0, //
    h02, h12, 0, 1, //
  ];
}

/// Casts the ray through screen pixel ([sx], [sy]) onto the ground plane
/// y = 0, returning east/south metres around the world origin.
///
/// [invVp] is the inverted view-projection matrix, [eye] the camera position
/// (must be above the plane — the flight cameras clamp it ≥ 2 m). Returns
/// `null` when the ray points at the sky or runs parallel to the plane.
/// Pure — unit-tested.
({double x, double z})? rayGroundHit({
  required Matrix4 invVp,
  required Vector3 eye,
  required double sx,
  required double sy,
  required double viewW,
  required double viewH,
}) {
  if (eye.y <= 0) return null;
  final nx = sx / viewW * 2 - 1;
  final ny = 1 - sy / viewH * 2;
  final world = invVp.transformed(Vector4(nx, ny, 0, 1));
  if (world.w.abs() < 1e-12) return null;
  final iw = 1 / world.w;
  final dx = world.x * iw - eye.x;
  final dy = world.y * iw - eye.y;
  final dz = world.z * iw - eye.z;
  // Downward only: skyward and parallel rays never meet the plane ahead.
  if (dy >= -1e-9) return null;
  final t = -eye.y / dy;
  return (x: eye.x + dx * t, z: eye.z + dz * t);
}

// ── Fetching & stitching ─────────────────────────────────────────────────────

/// One stitched satellite patch with exact geo bounds.
class SatellitePatch {
  final ui.Image image;
  final double northLat;
  final double southLat;
  final double westLon;
  final double eastLon;

  /// Half-extent (m) actually covered, for clamping the rendered area.
  final double coverageHalfMeters;

  /// Mean imagery color, so the procedural far terrain can pick up the local
  /// landscape (fields vs. city) instead of a flat grey.
  final ui.Color averageColor;

  const SatellitePatch({
    required this.image,
    required this.northLat,
    required this.southLat,
    required this.westLon,
    required this.eastLon,
    required this.coverageHalfMeters,
    required this.averageColor,
  });
}

/// Averages raw RGBA bytes (as from `Image.toByteData`) to one opaque color.
/// Pure — unit-tested. Falls back to a neutral sage on empty input.
ui.Color averageRgba(Uint8List bytes) {
  var r = 0, g = 0, b = 0, n = 0;
  for (var i = 0; i + 3 < bytes.length; i += 4) {
    r += bytes[i];
    g += bytes[i + 1];
    b += bytes[i + 2];
    n++;
  }
  if (n == 0) return const ui.Color(0xFFB7BCAE);
  return ui.Color.fromARGB(255, r ~/ n, g ~/ n, b ~/ n);
}

/// Mean color of [image], via a 48 px downscale so even a 9-tile stitch is
/// cheap to read back. Never throws — falls back to neutral sage.
Future<ui.Color> patchAverageColor(ui.Image image) async {
  try {
    const s = 48.0;
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);
    canvas.drawImageRect(
      image,
      ui.Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
      ui.Rect.fromLTWH(0, 0, s, s),
      ui.Paint()..filterQuality = ui.FilterQuality.low,
    );
    final picture = recorder.endRecording();
    final small = await picture.toImage(s.toInt(), s.toInt());
    picture.dispose();
    try {
      final data =
          await small.toByteData(format: ui.ImageByteFormat.rawRgba);
      if (data == null) return const ui.Color(0xFFB7BCAE);
      return averageRgba(data.buffer.asUint8List());
    } finally {
      small.dispose();
    }
  } catch (_) {
    return const ui.Color(0xFFB7BCAE);
  }
}

/// Fetches one tile's raw bytes (`null` on failure). Injectable for tests.
typedef SatTileFetcher = Future<Uint8List?> Function(Uri url);

/// Default fetcher: flutter_map's shared disk cache first (so settings'
/// "preload tiles" also warms the 3D satellite view, and vice versa), then
/// network with the result stored back.
Future<Uint8List?> _cachedFetcher(Uri url) async {
  final key = url.toString();
  final cache = BuiltInMapCachingProvider.getOrCreateInstance();
  if (cache.isSupported) {
    try {
      final hit = await cache.getTile(key);
      if (hit != null && hit.bytes.isNotEmpty) return hit.bytes;
    } catch (_) {
      // Corrupt entry — fall through to a fresh download below.
    }
  }
  final bytes = await fetchTileBytes(url);
  // Validate like the map precache does: HTML error pages must not poison
  // the shared cache (they fail image decode below, but would still store).
  if (bytes != null && !looksLikeImage(bytes)) return null;
  if (bytes != null) await putTileCached(key, bytes);
  return bytes;
}

String _key(double lat, double lon, double halfMeters) =>
    '${lat.toStringAsFixed(4)},${lon.toStringAsFixed(4)},${halfMeters.toStringAsFixed(0)}';

final Map<String, Future<SatellitePatch?>> _patchCache = {};

/// Stitched Esri patch centred on [lat]/[lon] covering ±[halfMeters]
/// (plus margin). Cached by rounded centre/extent; `null` when offline or on
/// any tile failure (callers fall back to plain ground). Failures are NOT
/// cached, so a later call retries instead of staying blank for the session.
Future<SatellitePatch?> fetchSatellitePatch({
  required double lat,
  required double lon,
  required double halfMeters,
  SatTileFetcher fetcher = _cachedFetcher,
}) {
  final key = _key(lat, lon, halfMeters);
  final hit = _patchCache[key];
  if (hit != null) return hit;
  final future = () async {
    try {
      return await _fetch(lat, lon, halfMeters, fetcher);
    } catch (_) {
      return null;
    }
  }().then<SatellitePatch?>((patch) {
    if (patch == null) _patchCache.remove(key);
    return patch;
  });
  _patchCache[key] = future;
  return future;
}

/// Fetches tile (wx, y, zoom); when the server has no imagery at that level
/// (Esri caps rural areas around 17–18), falls back to the parent tile one
/// level up and returns which quadrant of it to crop. Returns `null` only
/// when both fail.
Future<(Uint8List? bytes, int qx, int qy, int qz)> _fetchTileImage(
  SatTileFetcher fetcher,
  int wx,
  int y,
  int zoom,
) async {
  Uri url(int x, int y, int z) =>
      Uri.parse(satelliteTileUrl(x, y, z));
  final bytes = await fetcher(url(wx, y, zoom));
  if (bytes != null) return (bytes, 0, 0, zoom);
  if (zoom <= 10) return (null, 0, 0, zoom);
  final n = 1 << (zoom - 1);
  final px = ((wx >> 1) % n + n) % n;
  final py = (y >> 1).clamp(0, n - 1);
  final parent = await fetcher(url(px, py, zoom - 1));
  if (parent == null) return (null, 0, 0, zoom);
  return (parent, wx & 1, y & 1, zoom - 1);
}

Future<SatellitePatch?> _fetch(
  double lat,
  double lon,
  double halfMeters,
  SatTileFetcher fetcher,
) async {
  final zoom = satZoomForHalfMeters(halfMeters, lat);
  final mpp = satMetresPerPixel(lat, zoom);
  final tileM = mpp * 256;
  // Tile window around the centre, with margin for the scene plus label room.
  final r = (halfMeters * 1.4 / tileM).ceil().clamp(1, 4);
  final cx = satTileX(lon, zoom);
  final cy = satTileY(lat, zoom);
  final n = 1 << zoom;
  final minX = cx - r;
  final maxX = cx + r;
  final minY = math.max(0, cy - r);
  final maxY = math.min(n - 1, cy + r);

  final cols = maxX - minX + 1;
  final rows = maxY - minY + 1;
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder);
  // Underlay in the surfaces voice so missing tiles read as unloaded
  // imagery (not a white hole) in both modes.
  canvas.drawRect(
    ui.Rect.fromLTWH(0, 0, cols * 256, rows * 256),
    ui.Paint()..color = _uiColor(AppColors.muted),
  );

  var anyTile = false;
  for (var y = minY; y <= maxY; y++) {
    for (var x = minX; x <= maxX; x++) {
      // Wrap horizontally (tiles repeat around the antimeridian).
      final wx = ((x % n) + n) % n;
      final (bytes, qx, qy, qz) =
          await _fetchTileImage(fetcher, wx, y, zoom);
      if (bytes == null) continue;
      try {
        final codec = await ui.instantiateImageCodec(bytes);
        final frame = await codec.getNextFrame();
        final tile = frame.image;
        // Native tile: full image. Parent fallback: the quadrant we stand in,
        // upscaled to full size.
        final src = qz == zoom
            ? ui.Rect.fromLTWH(
                0, 0, tile.width.toDouble(), tile.height.toDouble())
            : ui.Rect.fromLTWH(
                qx * tile.width / 2,
                qy * tile.height / 2,
                tile.width / 2,
                tile.height / 2,
              );
        final dst = ui.Rect.fromLTWH(
          (x - minX) * 256.0,
          (y - minY) * 256.0,
          256.0,
          256.0,
        );
        canvas.drawImageRect(tile, src, dst, ui.Paint());
        tile.dispose();
        anyTile = true;
      } catch (_) {
        // Skip undecodable tiles; the underlay shows through.
      }
    }
  }
  if (!anyTile) return null;

  final picture = recorder.endRecording();
  final image = await picture.toImage(cols * 256, rows * 256);
  picture.dispose();

  // Unwrapped edges keep the UV math continuous (antimeridian-safe); the
  // fetched tiles wrap, the bounds don't have to.
  final north = satTileLatNorth(minY, zoom);
  final south = satTileLatNorth(maxY + 1, zoom);
  final west = minX / (1 << zoom) * 360 - 180;
  final east = (maxX + 1) / (1 << zoom) * 360 - 180;
  final midLat = (north + south) / 2;
  final coverage = math.min(
        (north - south) * metresPerDegreeLat,
        (east - west) *
            metresPerDegreeLat *
            math.cos(midLat * math.pi / 180),
      ) /
      2;
  return SatellitePatch(
    image: image,
    northLat: north,
    southLat: south,
    westLon: west,
    eastLon: east,
    coverageHalfMeters: coverage,
    averageColor: await patchAverageColor(image),
  );
}
