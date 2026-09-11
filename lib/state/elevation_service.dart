import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show consolidateHttpClientResponseBytes;
import 'package:flutter_map/flutter_map.dart'
    show BuiltInMapCachingProvider, CachedMapTileMetadata;

import '../core/app_config.dart';

/// Lightweight MSL elevation look-up using the same AWS Terrarium tiles as
/// the 3D satellite view (zoom 12, ≈24 m/px at 50° lat — well within the
/// precision needed for a dead-reckoning ground-collision clamp).
///
/// ### Cache behaviour
/// 1. Checks flutter_map's shared disk cache first — preloaded launch sites
///    ([precacheLaunchSites]) already include z=12 DEM tiles, so field
///    sessions never hit the network.
/// 2. On a miss, fetches the single tile from AWS S3 (no key required) and
///    writes it back to the shared disk cache so the next session is warm.
/// 3. Decoded tile bytes are kept in a per-session memory cache — repeated
///    queries over the same ≈6 km tile area (typical for a model rocket
///    flight) are instant after the first resolve.
///
/// Returns `null` on any failure; the caller falls back to the GPS-minimum
/// heuristic.

// ── Tile URL (mirrors satellite_ground.dart demTileUrl) ────────────────────

/// AWS Terrain Tiles in Terrarium encoding — no API key required.
String _demTileUrl(int x, int y, int z) =>
    'https://s3.amazonaws.com/elevation-tiles-prod/terrarium/$z/$x/$y.png';

// ── Slippy-map math (duplicated from slippy_math.dart to avoid ui→state dep) ─

int _tileX(double lon, int zoom) {
  final n = 1 << zoom;
  return ((lon + 180) / 360 * n).floor().clamp(0, n - 1);
}

int _tileY(double lat, int zoom) {
  final n = 1 << zoom;
  final rad = lat * math.pi / 180;
  final y = ((1 - math.log(math.tan(rad) + 1 / math.cos(rad)) / math.pi) /
          2 *
          n)
      .floor();
  return y.clamp(0, n - 1);
}

/// Returns the sub-tile pixel column [0, 255] for [lon] within tile [tx].
int _pixelX(double lon, int zoom, int tx) {
  final n = 1 << zoom;
  final exact = (lon + 180) / 360 * n - tx;
  return (exact * 256).floor().clamp(0, 255);
}

/// Returns the sub-tile pixel row [0, 255] for [lat] within tile [ty].
int _pixelY(double lat, int zoom, int ty) {
  final n = 1 << zoom;
  final rad = lat * math.pi / 180;
  final mercY =
      (1 - math.log(math.tan(rad) + 1 / math.cos(rad)) / math.pi) / 2 * n;
  return ((mercY - ty) * 256).floor().clamp(0, 255);
}

// ── Terrarium height decode (one line from satellite_ground.dart) ────────────

/// Decodes one Terrarium pixel to metres above sea level.
double _terrariumHeight(int r, int g, int b) =>
    r * 256.0 + g + b / 256.0 - 32768.0;

// ── In-memory tile cache ─────────────────────────────────────────────────────

// Keyed by "$zoom/$x/$y" → decoded RGBA bytes of the 256×256 tile.
// Futures are stored so concurrent queries for the same tile coalesce.
final Map<String, Future<Uint8List?>> _pixelCache = {};

Future<Uint8List?> _loadTilePixels(int tx, int ty) async {
  const zoom = 12; // matches the 3D DEM zoom
  final url = _demTileUrl(tx, ty, zoom);

  Uint8List? rawBytes;

  // 1. Disk cache (shared with the 3D view and the map precacher).
  final cache = BuiltInMapCachingProvider.getOrCreateInstance();
  if (cache.isSupported) {
    try {
      final hit = await cache.getTile(url);
      if (hit != null && hit.bytes.isNotEmpty) rawBytes = hit.bytes;
    } catch (_) {
      // Corrupt entry — fall through to a fresh download.
    }
  }

  // 2. Network fetch.
  if (rawBytes == null) {
    try {
      final client = HttpClient();
      client.connectionTimeout = AppConfig.tileConnectionTimeout;
      try {
        final request = await client.getUrl(Uri.parse(url));
        request.headers.set('User-Agent', AppConfig.tileUserAgent);
        final response =
            await request.close().timeout(AppConfig.tileResponseTimeout);
        if (response.statusCode == 200) {
          final bytes = await consolidateHttpClientResponseBytes(response);
          if (bytes.isNotEmpty) rawBytes = bytes;
        }
      } finally {
        client.close();
      }
    } catch (_) {
      return null;
    }

    // Write back to disk cache (same TTL as map tiles) so future sessions hit.
    if (rawBytes != null && cache.isSupported) {
      try {
        await cache.putTile(
          url: url,
          metadata: CachedMapTileMetadata(
            staleAt: DateTime.timestamp().add(AppConfig.tileCacheTtl),
            lastModified: null,
            etag: null,
          ),
          bytes: rawBytes,
        );
      } catch (_) {
        // Non-fatal — we still have the bytes in memory.
      }
    }
  }

  if (rawBytes == null) return null;

  // Decode PNG → raw RGBA so we can read individual pixel values.
  try {
    final codec = await ui.instantiateImageCodec(rawBytes);
    final frame = await codec.getNextFrame();
    final image = frame.image;
    try {
      final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      return data?.buffer.asUint8List();
    } finally {
      image.dispose();
    }
  } catch (_) {
    return null;
  }
}

/// Returns the MSL elevation (metres) at [lat]/[lon], or `null` on failure.
///
/// One z=12 Terrarium tile covers ≈6 km at 50° lat (≈24 m/px) — adequate
/// for a ground-collision clamp.  The result reflects absolute terrain height
/// above the WGS84 geoid; for model rockets that fly a few km this is
/// virtually identical to the GPS altitude datum.
///
/// The tile is fetched at most once per session (memory-cached); subsequent
/// calls inside the same ≈6 km tile area are synchronous after the first
/// resolve.
Future<double?> elevationMsl(double lat, double lon) async {
  const zoom = 12;
  final tx = _tileX(lon, zoom);
  final ty = _tileY(lat, zoom);
  final key = '$zoom/$tx/$ty';

  final pixels = await _pixelCache.putIfAbsent(key, () => _loadTilePixels(tx, ty));
  if (pixels == null) return null;

  final px = _pixelX(lon, zoom, tx);
  final py = _pixelY(lat, zoom, ty);

  final i = (py * 256 + px) * 4;
  if (i + 2 >= pixels.length) return null;

  return _terrariumHeight(pixels[i], pixels[i + 1], pixels[i + 2]);
}

/// The z=12 tile key ("12/x/y") for the given coordinates.
/// [TelemetryStore] uses this to avoid re-querying the same tile.
String elevationTileKey(double lat, double lon) {
  const zoom = 12;
  return '$zoom/${_tileX(lon, zoom)}/${_tileY(lat, zoom)}';
}
