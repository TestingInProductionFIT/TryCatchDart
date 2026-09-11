import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:trycatch/state/launch_site_store.dart';
import 'package:trycatch/ui/tiles/shared/map_tiles.dart';
import 'package:trycatch/ui/tiles/shared/offline_fallback_tiles.dart';
import 'package:trycatch/ui/tiles/shared/tile_io.dart';

void main() {
  group('tile URL builders', () {
    test('street URLs use Esri World Street Map (no subdomains)', () {
      expect(streetTileUrl(10, 20, 15),
          'https://server.arcgisonline.com/ArcGIS/rest/services/World_Street_Map/MapServer/tile/15/20/10');
      expect(streetTileUrl(11, 20, 15),
          'https://server.arcgisonline.com/ArcGIS/rest/services/World_Street_Map/MapServer/tile/15/20/11');
    });

    test('satellite URLs carry x/y/z in Esri order', () {
      expect(satelliteTileUrl(123, 456, 15),
          'https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/15/456/123');
    });

    test('precache count scales with sites', () {
      const site = LaunchSite(
          name: 'pad', latitude: 50.0, longitude: 14.0, altitudeMsl: 200);
      final one = precacheTileCount([site]);
      expect(one, greaterThan(0));
      expect(precacheTileCount([site, site]), one * 2);
      expect(precacheTileCount(const []), 0);
    });

    test('precache warms the 3D terrain set too', () {
      const site = LaunchSite(
          name: 'pad', latitude: 50.0, longitude: 14.0, altitudeMsl: 200);
      final urls = precacheUrlsForSites([site]);
      expect(urls.any((u) => u.contains('terrarium')), isTrue);
      expect(urls.any((u) => u.contains('World_Imagery')), isTrue);
    });

    test('precache covers detail zooms 18-19 around the centre', () {
      expect(precacheMinZoom, 13);
      expect(precacheMaxZoom, 19);
      expect(precacheRadiusMeters(17), 1000.0);
      expect(precacheRadiusMeters(18), 500.0);
      expect(precacheRadiusMeters(19), 500.0);
      const site = LaunchSite(
          name: 'pad', latitude: 50.0, longitude: 14.0, altitudeMsl: 200);
      // Detail levels stay bounded: central ~1 km across, not full 1 km radius.
      expect(precacheTileRadius(site.latitude, 19), lessThanOrEqualTo(11));
      final urls = precacheUrlsForSites([site]);
      expect(
        urls.any((u) => u.contains('/19/')),
        isTrue,
      );
    });
  });

  group('offline fallback math', () {
    test('wrapX wraps around the antimeridian', () {
      expect(wrapX(0, 2), 0);
      expect(wrapX(4, 2), 0);
      expect(wrapX(-1, 2), 3);
    });

    test('parent coords halve per level', () {
      final p = parentTileCoords(10, 6, 5, 1);
      expect((p.x, p.y, p.z), (5, 3, 4));
      final q = parentTileCoords(10, 6, 5, 2);
      expect((q.x, q.y, q.z), (2, 1, 3));
    });

    test('quadrant locates the child inside its parent', () {
      // Child (10, 6, 5) inside parent (5, 3, 4): scale 2, cell (0, 0).
      final q = quadrantForChild(10, 6, 5, 5, 3, 4);
      expect((q.qx, q.qy, q.scale), (0, 0, 2));
      final q2 = quadrantForChild(11, 7, 5, 5, 3, 4);
      expect((q2.qx, q2.qy, q2.scale), (1, 1, 2));
    });

    test('quadrant spans multi-level ancestors', () {
      // Child (22, 13, 6) under grandparent (5, 3, 4): scale 4.
      final q = quadrantForChild(22, 13, 6, 5, 3, 4);
      expect((q.qx, q.qy, q.scale), (2, 1, 4));
    });
  });

  group('map backgrounds', () {
    test('satellite background is dark, street is light', () {
      // Loading/error tiles paint nothing, so gaps show the map background:
      // dark behind imagery, pale behind street tiles — never white flash.
      expect(satelliteMapBackground.computeLuminance(), lessThan(0.05));
      expect(streetMapBackground.computeLuminance(), greaterThan(0.7));
    });
  });

  group('parent crop fallback', () {
    test('crop extracts the child quadrant at full size', () async {
      final parent = await _quadrantPng();
      // Child (0, 0, 1) is the top-left quadrant (red).
      final bytes = await cropParentTile(parent, 0, 0, 1, 0, 0, 0);
      expect(bytes, isNotNull);
      expect(looksLikeImage(bytes!), isTrue);
      final center = await _centerPixel(bytes);
      expect(center, [255, 0, 0, 255]);
    });

    test('out-of-range crops stay null without touching the cache', () async {
      croppedTileCache.clear();
      final parent = await _quadrantPng();
      expect(await cropParentTile(parent, 5, 5, 1, 0, 0, 0), isNull);
      expect(await cropParentTile(parent, 0, 0, 1, 9, 9, 0), isNull);
      expect(croppedTileCache.length, 0);
    });

    test('repeat crops are served from memory', () async {
      croppedTileCache.clear();
      final parent = await _quadrantPng();
      final first = await cropParentTile(parent, 1, 0, 1, 0, 0, 0);
      expect(first, isNotNull);
      expect(croppedTileCache.length, 1);
      final second = await cropParentTile(parent, 1, 0, 1, 0, 0, 0);
      expect(second, isNotNull);
      expect(second, first);
      expect(croppedTileCache.length, 1);
    });
  });

  group('cropped tile cache', () {
    test('evicts least-recently-used first', () {
      final cache = CroppedTileCache(capacity: 2);
      final a = Uint8List.fromList([1]);
      final b = Uint8List.fromList([2]);
      final c = Uint8List.fromList([3]);
      cache.put('a', a);
      cache.put('b', b);
      expect(cache.get('a'), same(a)); // refreshes 'a'
      cache.put('c', c);
      expect(cache.get('b'), isNull);
      expect(cache.get('a'), same(a));
      expect(cache.get('c'), same(c));
    });
  });

  group('placeholder tiles', () {
    test('non-image bytes are unusable', () {
      expect(isUsableTileBytes(Uint8List(0)), isFalse);
      expect(
          isUsableTileBytes(
              Uint8List.fromList('oops'.codeUnits)),
          isFalse);
    });

    test('image magic with ordinary length is usable, not placeholder', () {
      // PNG magic + filler at a length no placeholder uses.
      final bytes = Uint8List(100);
      bytes[0] = 0x89;
      bytes[1] = 0x50;
      bytes[2] = 0x4E;
      bytes[3] = 0x47;
      expect(isEsriPlaceholderTile(bytes), isFalse);
      expect(isUsableTileBytes(bytes), isTrue);
    });

    test('placeholder-length noise is not mistaken for a placeholder', () {
      // Right length, wrong hash: exact SHA match required.
      final bytes = Uint8List(2521);
      bytes[0] = 0xFF;
      bytes[1] = 0xD8;
      bytes[2] = 0xFF;
      bytes[3] = 0x00;
      expect(isEsriPlaceholderTile(bytes), isFalse);
      expect(isUsableTileBytes(bytes), isTrue);
    });
  });
}

/// 256×256 test tile with a solid color per quadrant:
/// TL red, TR green, BL blue, BR white.
Future<Uint8List> _quadrantPng() async {
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder);
  void quad(double left, double top, ui.Color color) {
    canvas.drawRect(
      ui.Rect.fromLTWH(left, top, 128, 128),
      ui.Paint()..color = color,
    );
  }

  quad(0, 0, const ui.Color(0xFFFF0000));
  quad(128, 0, const ui.Color(0xFF00FF00));
  quad(0, 128, const ui.Color(0xFF0000FF));
  quad(128, 128, const ui.Color(0xFFFFFFFF));
  final picture = recorder.endRecording();
  final image = await picture.toImage(256, 256);
  picture.dispose();
  try {
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    return data!.buffer.asUint8List();
  } finally {
    image.dispose();
  }
}

/// Decodes [png] and returns the RGBA center pixel.
Future<List<int>> _centerPixel(Uint8List png) async {
  final codec = await ui.instantiateImageCodec(png);
  final frame = await codec.getNextFrame();
  final image = frame.image;
  expect(image.width, 256);
  expect(image.height, 256);
  try {
    final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    final bytes = data!.buffer.asUint8List();
    final i = (128 * 256 + 128) * 4;
    return bytes.sublist(i, i + 4);
  } finally {
    image.dispose();
  }
}
