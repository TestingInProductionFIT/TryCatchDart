import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:trycatch/core/geo.dart';
import 'package:trycatch/ui/tiles/shared/satellite_ground.dart';
import 'package:vector_math/vector_math_64.dart';

void main() {
  group('slippy tile math', () {
    test('tile contains its source point', () {
      for (final (lat, lon, zoom) in [
        (50.0755, 14.4378, 15), // Prague
        (0.0, 0.0, 10),
        (-33.8688, 151.2093, 12), // Sydney
        (40.7128, -74.0060, 16), // New York
      ]) {
        final x = satTileX(lon, zoom);
        final y = satTileY(lat, zoom);
        final west = satTileLonWest(x, zoom);
        final east = satTileLonWest(x + 1, zoom);
        final north = satTileLatNorth(y, zoom);
        final south = satTileLatNorth(y + 1, zoom);
        expect(lon, inInclusiveRange(west, east));
        expect(lat, inInclusiveRange(south, north));
      }
    });

    test('tile X wraps longitude, Y clamps latitude', () {
      final n = 1 << 12;
      expect(satTileX(180, 12), n - 1);
      expect(satTileX(-180, 12), 0);
      expect(satTileY(85.0511, 12), 0);
      expect(satTileY(-85.0511, 12), n - 1);
    });

    test('zoom grows as the requested extent shrinks', () {
      const lat = 50.0;
      final zNear = satZoomForHalfMeters(60, lat);
      final zFar = satZoomForHalfMeters(2000, lat);
      expect(zNear, greaterThan(zFar));
      expect(zNear, inInclusiveRange(10, 19));
      expect(zFar, inInclusiveRange(10, 19));
    });

    test('metres-per-pixel halves per zoom level', () {
      expect(
        satMetresPerPixel(50, 15),
        closeTo(2 * satMetresPerPixel(50, 16), 1e-9),
      );
    });
  });

  group('solveHomography', () {
    ({double x, double y}) apply(List<double> h, double u, double v) {
      final w = h[6] * u + h[7] * v + 1;
      return (
        x: (h[0] * u + h[1] * v + h[2]) / w,
        y: (h[3] * u + h[4] * v + h[5]) / w,
      );
    }

    test('identity maps corners onto themselves', () {
      final src = [(x: 0.0, y: 0.0), (x: 1.0, y: 0.0), (x: 1.0, y: 1.0), (x: 0.0, y: 1.0)];
      final h = solveHomography(src, src)!;
      for (final p in src) {
        final q = apply(h, p.x, p.y);
        expect(q.x, closeTo(p.x, 1e-9));
        expect(q.y, closeTo(p.y, 1e-9));
      }
    });

    test('perspective quad round-trips its corners', () {
      final src = [
        (x: 0.0, y: 0.0),
        (x: 800.0, y: 0.0),
        (x: 800.0, y: 600.0),
        (x: 0.0, y: 600.0),
      ];
      final dst = [
        (x: 100.0, y: 50.0),
        (x: 700.0, y: 80.0),
        (x: 640.0, y: 500.0),
        (x: 160.0, y: 470.0),
      ];
      final h = solveHomography(src, dst)!;
      for (var i = 0; i < 4; i++) {
        final q = apply(h, src[i].x, src[i].y);
        expect(q.x, closeTo(dst[i].x, 1e-6));
        expect(q.y, closeTo(dst[i].y, 1e-6));
      }
      // Interior point lands inside the quad (no wild extrapolation).
      final mid = apply(h, 400, 300);
      expect(mid.x, inInclusiveRange(100, 700));
      expect(mid.y, inInclusiveRange(50, 500));
    });

    test('degenerate correspondences return null', () {
      final line = [(x: 0.0, y: 0.0), (x: 1.0, y: 0.0), (x: 2.0, y: 0.0), (x: 3.0, y: 0.0)];
      final dst = [(x: 0.0, y: 0.0), (x: 1.0, y: 0.0), (x: 1.0, y: 1.0), (x: 0.0, y: 1.0)];
      expect(solveHomography(line, dst), isNull);
    });

    test('homographyMatrix embeds coefficients for Canvas.transform', () {
      final m = homographyMatrix([1, 0, 10, 0, 1, 20, 0, 0]);
      expect(m.length, 16);
      // Column-major: translation lands in the last column.
      expect(m[12], 10);
      expect(m[13], 20);
      expect(m[15], 1);
    });
  });

  group('satUvFraction', () {
    test('centre maps to centre, cardinals to edges', () {
      const lat0 = 50.5;
      const lon0 = 14.5;
      final cosLat0 = math.cos(lat0 * math.pi / 180);

      ({double u, double v}) uv(double eastM, double southM) =>
          satUvFraction(
            eastM,
            southM,
            lat0,
            lon0,
            cosLat0,
            northLat: 51.0,
            southLat: 50.0,
            westLon: 14.0,
            eastLon: 15.0,
          );

      final centre = uv(0, 0);
      expect(centre.u, closeTo(0.5, 1e-9));
      expect(centre.v, closeTo(0.5, 1e-9));

      // 0.25° east → u 0.75.
      final eastM = 0.25 * metresPerDegreeLat * cosLat0;
      expect(uv(eastM, 0).u, closeTo(0.75, 1e-9));

      // 0.25° north (negative world Z) → v 0.25.
      final northM = 0.25 * metresPerDegreeLat;
      expect(uv(0, -northM).v, closeTo(0.25, 1e-9));
    });
  });

  group('rayGroundHit', () {
    Matrix4 vpFor(Vector3 eye, Vector3 target) {
      final proj = makePerspectiveMatrix(
          50 * math.pi / 180, 800 / 600, 0.5, 120000);
      return proj * makeViewMatrix(eye, target, Vector3(0, 1, 0));
    }

    test('screen centre ray hits the look target', () {
      final eye = Vector3(0, 500, 50);
      final vp = vpFor(eye, Vector3(0, 0, 0));
      final inv = vp.clone()..invert();
      final hit = rayGroundHit(
        invVp: inv,
        eye: eye,
        sx: 400,
        sy: 300,
        viewW: 800,
        viewH: 600,
      )!;
      expect(hit.x, closeTo(0, 1e-6));
      expect(hit.z, closeTo(0, 1e-6));
    });

    test('skyward rays miss, ground rays hit ahead', () {
      final eye = Vector3(0, 10, 0);
      final vp = vpFor(eye, Vector3(5000, 10, 0));
      final inv = vp.clone()..invert();
      // Top-centre pixel looks above the horizon.
      expect(
        rayGroundHit(
          invVp: inv,
          eye: eye,
          sx: 400,
          sy: 0,
          viewW: 800,
          viewH: 600,
        ),
        isNull,
      );
      // Bottom-centre pixel lands on the ground ahead.
      final hit = rayGroundHit(
        invVp: inv,
        eye: eye,
        sx: 400,
        sy: 599,
        viewW: 800,
        viewH: 600,
      )!;
      expect(hit.x, greaterThan(0));
    });
  });

  group('averageRgba', () {
    test('solid color round-trips', () {
      final bytes = Uint8List.fromList([200, 100, 50, 255, 200, 100, 50, 255]);
      final c = averageRgba(bytes);
      expect(c.a, 1.0);
      expect((c.r * 255).round(), 200);
      expect((c.g * 255).round(), 100);
      expect((c.b * 255).round(), 50);
    });

    test('empty input falls back to neutral sage', () {
      expect(averageRgba(Uint8List(0)).toARGB32(), 0xFFB7BCAE);
    });
  });
}
