import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show consolidateHttpClientResponseBytes;
import 'package:flutter_map/flutter_map.dart';

import '../../settings/launch_site_store.dart';
import 'satellite_ground.dart';

/// Map tile sources + offline precaching around launch sites.
///
/// Street layer is Esri World Street Map (bright, worldwide, no key — the
/// same reliable infra as the satellite layer; OSM-FR renders patchy 404s
/// and OSM.org is policy-restricted). Satellite stays Esri World Imagery
/// but overzooms past its native ceiling instead of going blank.
/// Both layers ride flutter_map's built-in disk cache
/// ([BuiltInMapCachingProvider], 1 GB), and [precacheLaunchSites] fills that
/// same cache around saved sites so the field map works offline.

// ── URL builders (must match flutter_map's own template expansion) ──────────

/// Esri street-map URL for a tile (single host, no subdomains).
String streetTileUrl(int x, int y, int z) =>
    'https://server.arcgisonline.com/ArcGIS/rest/services/World_Street_Map/MapServer/tile/$z/$y/$x';

/// Esri World Imagery URL for a tile.
String satelliteTileUrl(int x, int y, int z) =>
    'https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/$z/$y/$x';

// ── Layers ───────────────────────────────────────────────────────────────────

TileLayer buildStreetLayer() => TileLayer(
      urlTemplate:
          'https://server.arcgisonline.com/ArcGIS/rest/services/World_Street_Map/MapServer/tile/{z}/{y}/{x}',
      userAgentPackageName: 'dev.trycatch.groundstation',
      maxZoom: 19,
      maxNativeZoom: 18,
    );

TileLayer buildSatelliteLayer() => TileLayer(
      urlTemplate:
          'https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}',
      userAgentPackageName: 'dev.trycatch.groundstation',
      // Esri rarely serves past 18 — overzoom from there instead of blanking.
      maxZoom: 19,
      maxNativeZoom: 18,
    );

const String streetAttribution = '© Esri, OpenStreetMap contributors';
const String satelliteAttribution = 'Imagery © Esri';

// ── Precaching ───────────────────────────────────────────────────────────────

/// Result of a precache run.
typedef PrecacheResult = ({int fetched, int total});

/// Downloads street + satellite tiles around [sites] (zooms 13–17, ~1 km
/// radius) into flutter_map's disk cache. Fire-and-forget friendly; skips
/// tiles already cached and tolerates offline (returns what it managed).
Future<PrecacheResult> precacheLaunchSites(
  List<LaunchSite> sites, {
  void Function(int done, int total)? onProgress,
}) async {
  final urls = <String>[];
  for (final site in sites) {
    for (var zoom = 13; zoom <= 17; zoom++) {
      final mpp = satMetresPerPixel(site.latitude, zoom);
      final r = (1000 / (mpp * 256)).ceil().clamp(1, 3);
      final cx = satTileX(site.longitude, zoom);
      final cy = satTileY(site.latitude, zoom);
      final n = 1 << zoom;
      for (var y = cy - r; y <= cy + r; y++) {
        if (y < 0 || y >= n) continue;
        for (var x = cx - r; x <= cx + r; x++) {
          final wx = ((x % n) + n) % n;
          urls.add(streetTileUrl(x, y, zoom));
          urls.add(satelliteTileUrl(wx, y, zoom));
        }
      }
    }
  }

  final cache = BuiltInMapCachingProvider.getOrCreateInstance();
  if (!cache.isSupported) return (fetched: 0, total: urls.length);

  final client = HttpClient();
  client.connectionTimeout = const Duration(seconds: 8);
  var fetched = 0;
  var done = 0;
  try {
    for (final url in urls) {
      done++;
      try {
        if (await cache.getTile(url) != null) {
          onProgress?.call(done, urls.length);
          continue;
        }
        final bytes = await _get(client, Uri.parse(url));
        if (bytes != null && _looksLikeImage(bytes)) {
          await cache.putTile(
            url: url,
            metadata: CachedMapTileMetadata(
              staleAt:
                  DateTime.timestamp().add(const Duration(days: 30)),
              lastModified: null,
              etag: null,
            ),
            bytes: bytes,
          );
          fetched++;
        }
      } catch (_) {
        // Skip failures — precaching is best-effort.
      }
      onProgress?.call(done, urls.length);
    }
  } finally {
    client.close();
  }
  return (fetched: fetched, total: urls.length);
}

Future<Uint8List?> _get(HttpClient client, Uri url) async {
  try {
    final request = await client.getUrl(url);
    request.headers.set('User-Agent', 'dev.trycatch.groundstation');
    final response = await request.close().timeout(const Duration(seconds: 10));
    if (response.statusCode != 200) return null;
    final bytes = await consolidateHttpClientResponseBytes(response);
    return bytes.isEmpty ? null : bytes;
  } catch (_) {
    return null;
  }
}

/// PNG or JPEG magic bytes — keeps HTML error pages out of the tile cache
/// (Esri imagery is JPEG, CARTO street is PNG).
bool _looksLikeImage(Uint8List bytes) {
  if (bytes.length < 4) return false;
  final png = bytes[0] == 0x89 &&
      bytes[1] == 0x50 &&
      bytes[2] == 0x4E &&
      bytes[3] == 0x47;
  final jpeg =
      bytes[0] == 0xFF && bytes[1] == 0xD8 && bytes[2] == 0xFF;
  return png || jpeg;
}

/// Rough tile count (both layers) a precache run over [sites] would fetch.
/// Lets the UI warn before big downloads.
int precacheTileCount(List<LaunchSite> sites) {
  var total = 0;
  for (final site in sites) {
    for (var zoom = 13; zoom <= 17; zoom++) {
      final mpp = satMetresPerPixel(site.latitude, zoom);
      final r = (1000 / (mpp * 256)).ceil().clamp(1, 3);
      total += (2 * r + 1) * (2 * r + 1) * 2;
    }
  }
  return total;
}
