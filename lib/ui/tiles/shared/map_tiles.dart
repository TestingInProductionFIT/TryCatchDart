import 'dart:io';

import 'package:flutter_map/flutter_map.dart';

import '../../../state/launch_site_store.dart';
import './satellite_ground.dart';
import './tile_io.dart'
    show
        fetchTileBytes,
        looksLikeImage,
        putTileCached,
        satelliteTileUrl,
        streetTileUrl;

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

// Re-exported from tile_io for existing importers (map_widget, tests).
export './tile_io.dart'
    show
        satelliteAttribution,
        satelliteTileUrl,
        streetAttribution,
        streetTileUrl;

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

// ── Precaching ───────────────────────────────────────────────────────────────

/// Result of a precache run.
typedef PrecacheResult = ({int fetched, int total});

/// Per-site cache coverage: how many of the precache URL set are on disk.
typedef SiteCacheCoverage = ({LaunchSite site, int cached, int total});

/// The exact tile URL set a precache run over [sites] would fetch (street +
/// satellite, zooms 13–17, ~1 km radius). Shared by the downloader and the
/// coverage probe so both agree on what "cached" means.
List<String> precacheUrlsForSites(List<LaunchSite> sites) {
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
  return urls;
}

/// Checks how many of each site's precache tiles are already in
/// flutter_map's disk cache, by probing the same URL set the precache
/// downloads. The cache backend exposes no size/count stats, so per-URL
/// probing is the only way to "view" coverage. Read-only and offline-safe.
Future<List<SiteCacheCoverage>> tileCacheCoverage(
  List<LaunchSite> sites, {
  void Function(int done, int total)? onProgress,
}) async {
  final cache = BuiltInMapCachingProvider.getOrCreateInstance();
  final out = <SiteCacheCoverage>[];
  var done = 0;
  var grandTotal = 0;
  final perSite = <List<String>>[];
  for (final site in sites) {
    final urls = precacheUrlsForSites([site]);
    perSite.add(urls);
    grandTotal += urls.length;
  }
  for (var i = 0; i < sites.length; i++) {
    var cached = 0;
    if (cache.isSupported) {
      for (final url in perSite[i]) {
        done++;
        try {
          if (await cache.getTile(url) != null) cached++;
        } catch (_) {
          // Corrupt entries count as missing.
        }
        onProgress?.call(done, grandTotal);
      }
    } else {
      done += perSite[i].length;
      onProgress?.call(done, grandTotal);
    }
    out.add((site: sites[i], cached: cached, total: perSite[i].length));
  }
  return out;
}

/// Downloads street + satellite tiles around [sites] (zooms 13–17, ~1 km
/// radius) into flutter_map's disk cache. Fire-and-forget friendly; skips
/// tiles already cached and tolerates offline (returns what it managed).
Future<PrecacheResult> precacheLaunchSites(
  List<LaunchSite> sites, {
  void Function(int done, int total)? onProgress,
}) async {
  final urls = precacheUrlsForSites(sites);

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
        final bytes = await fetchTileBytes(client: client, Uri.parse(url));
        if (bytes != null && looksLikeImage(bytes)) {
          await putTileCached(url, bytes);
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
