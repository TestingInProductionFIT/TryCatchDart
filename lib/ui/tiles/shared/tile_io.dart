import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show consolidateHttpClientResponseBytes;
import 'package:flutter_map/flutter_map.dart'
    show BuiltInMapCachingProvider, CachedMapTileMetadata;

/// Shared Esri tile I/O for the 2D map and the 3D satellite drape: URL
/// builders, single-shot downloads and the shared flutter_map disk cache.
///
/// Both map precaching (`map_tiles.dart`) and the 3D patch fetcher
/// (`satellite_ground.dart`) go through here, so the User-Agent, timeouts,
/// image validation and cache TTL can't drift apart.

const String tileUserAgent = 'dev.trycatch.groundstation';

const String streetAttribution = '© Esri, OpenStreetMap contributors';
const String satelliteAttribution = 'Imagery © Esri';

/// Esri tile URL for a map style (`World_Street_Map` / `World_Imagery`).
String esriTileUrl(String style, int x, int y, int z) =>
    'https://server.arcgisonline.com/ArcGIS/rest/services/$style/MapServer/tile/$z/$y/$x';

/// Esri street-map URL for a tile (single host, no subdomains).
String streetTileUrl(int x, int y, int z) =>
    esriTileUrl('World_Street_Map', x, y, z);

/// Esri World Imagery URL for a tile.
String satelliteTileUrl(int x, int y, int z) =>
    esriTileUrl('World_Imagery', x, y, z);

/// Downloads [url] (`null` on any failure or empty body). Creates its own
/// client unless [client] is given (precache passes a shared one).
Future<Uint8List?> fetchTileBytes(Uri url, {HttpClient? client}) async {
  final owned = client == null;
  final http = client ?? HttpClient();
  try {
    http.connectionTimeout = const Duration(seconds: 8);
    final request = await http.getUrl(url);
    request.headers.set('User-Agent', tileUserAgent);
    final response =
        await request.close().timeout(const Duration(seconds: 10));
    if (response.statusCode != 200) return null;
    final bytes = await consolidateHttpClientResponseBytes(response);
    return bytes.isEmpty ? null : bytes;
  } catch (_) {
    return null;
  } finally {
    if (owned) http.close();
  }
}

/// PNG or JPEG magic bytes — keeps HTML error pages out of the tile cache
/// (Esri imagery is JPEG, street tiles are PNG).
bool looksLikeImage(Uint8List bytes) {
  if (bytes.length < 4) return false;
  final png = bytes[0] == 0x89 &&
      bytes[1] == 0x50 &&
      bytes[2] == 0x4E &&
      bytes[3] == 0x47;
  final jpeg =
      bytes[0] == 0xFF && bytes[1] == 0xD8 && bytes[2] == 0xFF;
  return png || jpeg;
}

/// Stores [bytes] in flutter_map's shared disk cache for 30 days.
/// Best-effort: cache write failures are swallowed.
Future<void> putTileCached(String url, Uint8List bytes) async {
  final cache = BuiltInMapCachingProvider.getOrCreateInstance();
  if (!cache.isSupported) return;
  try {
    await cache.putTile(
      url: url,
      metadata: CachedMapTileMetadata(
        staleAt: DateTime.timestamp().add(const Duration(days: 30)),
        lastModified: null,
        etag: null,
      ),
      bytes: bytes,
    );
  } catch (_) {
    // Cache write failure is non-fatal; the tile still displays.
  }
}
