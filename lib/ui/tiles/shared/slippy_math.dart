import 'dart:math' as math;
import 'package:vector_math/vector_math_64.dart';
import '../../../core/geo.dart';

/// Pure slippy-map math and 3D terrain projection geometry.
///
/// Unit-tested functions with zero Flutter UI dependencies.

// ── Pure slippy-map math ─────────────────────────────────────────────────────

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

/// Smoothstep (0→1) for edge fades.
double smoothstep(double t) => t * t * (3 - 2 * t);

/// Metres per pixel of Web-Mercator tiles at [zoom] and [lat].
double satMetresPerPixel(double lat, int zoom) =>
    156543.03392 * math.cos(lat * math.pi / 180) / (1 << zoom);

/// Zoom whose tiles cover [halfMeters] (half-extent) at roughly
/// [targetPixels] across.
int satZoomForHalfMeters(
  double halfMeters,
  double lat, {
  int targetPixels = 4096,
}) {
  var zoom = (math.log(156543.03392 *
              math.cos(lat * math.pi / 180) *
              targetPixels /
              (halfMeters * 2)) /
          math.ln2)
      .round();
  return zoom.clamp(10, 19);
}

/// World (east/south metres around lat0/lon0) → UV fractions into the given
/// geo bounds. v=0 is the north edge (image row 0).
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

// ── Ground Extents & Constants ───────────────────────────────────────────────

/// Fixed ground half-extent (m): 20×20 km around the launch site.
const double satFixedHalfMeters = 10000;

/// Half-extent (m) of the mid tier: central 10×10 km.
const double satMidHalfMeters = 5000;

/// Half-extent (m) of the pad tier: central 2.5×2.5 km.
const double satPadHalfMeters = 1250;

/// Outer context patch fetch parameters.
const int satOuterTargetPixels = 2048;
const int satOuterTileRadius = 4;

/// Mid tier patch fetch parameters.
const int satMidTargetPixels = 4096;
const int satMidTileRadius = 4;

/// Pad tier patch fetch parameters.
const int satPadTargetPixels = 4096;
const int satPadTileRadius = 3;

/// Rim-feather start fraction for drape tiers.
const double satFeatherStart = 0.7;

// ── Perspective Mapping & Clipping ───────────────────────────────────────────

/// Solves the 2D projective transform mapping [src] onto [dst] from 4
/// corner correspondences.
List<double>? solveHomography(
  List<({double x, double y})> src,
  List<({double x, double y})> dst,
) {
  assert(src.length == 4 && dst.length == 4);
  final a = List.generate(8, (_) => List.filled(9, 0.0));
  for (var i = 0; i < 4; i++) {
    final u = src[i].x, v = src[i].y;
    final x = dst[i].x, y = dst[i].y;
    a[2 * i] = [-u, -v, -1, 0, 0, 0, x * u, x * v, -x];
    a[2 * i + 1] = [0, 0, 0, -u, -v, -1, y * u, y * v, -y];
  }
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

/// Embeds 2D homography coefficients into a 4x4 column-major matrix.
List<double> homographyMatrix(List<double> h) {
  assert(h.length == 8);
  final h00 = h[0], h01 = h[1], h02 = h[2];
  final h10 = h[3], h11 = h[4], h12 = h[5];
  final h20 = h[6], h21 = h[7];
  return [
    h00, h10, 0, h20,
    h01, h11, 0, h21,
    0, 0, 1, 0,
    h02, h12, 0, 1,
  ];
}

/// Rim-feather alpha for a drape node [distM] from the anchor inside a tier.
double satRimAlpha(double distM, double coverageHalfMeters) {
  final ft = ((distM / coverageHalfMeters - satFeatherStart) /
          (1 - satFeatherStart))
      .clamp(0.0, 1.0);
  return 1 - ft * ft * (3 - 2 * ft);
}

/// One clip-space vertex of a drape triangle.
typedef ClipVert = ({
  Vector4 c,
  double u,
  double v,
  double shade,
  double alpha
});

/// Near-plane epsilon for drape clipping.
const double drapeClipEps = 1e-6;

/// Sutherland–Hodgman clip of triangle ([a], [b], [c]) against w = [eps].
List<ClipVert> clipTriangleNear(
  ClipVert a,
  ClipVert b,
  ClipVert c, [
  double eps = drapeClipEps,
]) {
  ClipVert lerp(ClipVert out, ClipVert inn, double t) => (
        c: out.c * (1 - t) + inn.c * t,
        u: out.u + (inn.u - out.u) * t,
        v: out.v + (inn.v - out.v) * t,
        shade: out.shade + (inn.shade - out.shade) * t,
        alpha: out.alpha + (inn.alpha - out.alpha) * t,
      );
  ClipVert cross(ClipVert out, ClipVert inn) {
    final denom = inn.c.w - out.c.w;
    if (denom.abs() < 1e-12) return inn;
    return lerp(out, inn, ((eps - out.c.w) / denom).clamp(0.0, 1.0));
  }

  final vs = [a, b, c];
  final clipped = <ClipVert>[];
  for (var i = 0; i < vs.length; i++) {
    final cur = vs[i];
    final prev = vs[(i + vs.length - 1) % vs.length];
    final curIn = cur.c.w > eps;
    final prevIn = prev.c.w > eps;
    if (curIn) {
      if (!prevIn) clipped.add(cross(prev, cur));
      clipped.add(cur);
    } else if (prevIn) {
      clipped.add(cross(cur, prev));
    }
  }
  return clipped;
}

/// Edge fade for raw (unclamped) patch UVs [u]/[v].
double satEdgeFade(double u, double v) {
  final ou = u < 0 ? -u : (u > 1 ? u - 1 : 0.0);
  final ov = v < 0 ? -v : (v > 1 ? v - 1 : 0.0);
  final over = math.max(ou, ov) / 0.03;
  if (over >= 1) return 0;
  final t = over.clamp(0.0, 1.0);
  return 1 - t * t * (3 - 2 * t);
}
