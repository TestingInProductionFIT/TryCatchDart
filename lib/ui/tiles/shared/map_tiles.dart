import 'dart:io';
import 'dart:ui' show Color;

import 'package:flutter_map/flutter_map.dart';

import '../../../state/launch_site_store.dart';
import './offline_fallback_tiles.dart';
import './satellite_ground.dart';
import './tile_io.dart'
    show
        fetchTileBytes,
        isUsableTileBytes,
        putTileCached,
        satelliteTileUrl,
        streetTileUrl;

/// Map tile sources + offline precaching around launch sites.
///
/// Street layer is Esri World Street Map (bright, worldwide, no key — the
/// same reliable infra as the satellite layer; OSM-FR renders patchy 404s
/// and OSM.org is policy-restricted). Satellite stays Esri World Imagery.
/// Missing high-res tiles fall back to the closest cached parent
/// ([OfflineFallbackTileProvider]) instead of going blank.
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

/// Map background behind the satellite layer: loading/error tiles paint
/// nothing, so every gap shows `MapOptions.backgroundColor`. A near-black
/// neutral blends with imagery instead of flashing white on every zoom step.
const Color satelliteMapBackground = Color(0xFF141414);

/// Map background behind the street layer: matches the pale paper tone of
/// the street tiles for the same reason.
const Color streetMapBackground = Color(0xFFE4E1D9);

TileLayer buildStreetLayer() => TileLayer(
      urlTemplate:
          'https://server.arcgisonline.com/ArcGIS/rest/services/World_Street_Map/MapServer/tile/{z}/{y}/{x}',
      userAgentPackageName: 'dev.trycatch.groundstation',
      maxZoom: 19,
      maxNativeZoom: 19,
      // No per-tile fade-in: during pan/zoom dozens of tiles arriving with
      // staggered opacity animations keeps the raster thread busy and reads
      // as jank. Tiles pop in the moment they decode instead.
      tileDisplay: const TileDisplay.instantaneous(),
      tileProvider: OfflineFallbackTileProvider(
        style: 'World_Street_Map',
      ),
    );

TileLayer buildSatelliteLayer() => TileLayer(
      urlTemplate:
          'https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}',
      userAgentPackageName: 'dev.trycatch.groundstation',
      // Esri rarely serves past 18 — missing high-res tiles fall back to
      // the closest cached parent via [OfflineFallbackTileProvider]
      // instead of blanking.
      maxZoom: 19,
      maxNativeZoom: 19,
      // Instantaneous for pan/zoom smoothness (see street layer above).
      tileDisplay: const TileDisplay.instantaneous(),
      tileProvider: OfflineFallbackTileProvider(
        style: 'World_Imagery',
      ),
    );

// ── Precaching ───────────────────────────────────────────────────────────────

/// Lowest zoom cached around launch sites.
const int precacheMinZoom = 13;

/// Highest zoom cached around launch sites (detail levels 18–19 cover the
/// central ~1 km across so close zoom-ins stay sharp).
const int precacheMaxZoom = 19;

/// Radius in metres cached at [zoom]: ~1 km around the site for zooms
/// 13–17, central ~1 km across (500 m radius) for the detail levels 18–19
/// so tile counts stay sane (~23×23 max at z19 instead of ~43×43).
double precacheRadiusMeters(int zoom) => zoom <= 17 ? 1000.0 : 500.0;

/// Tile radius (in tiles) cached at [zoom] for latitude [lat].
int precacheTileRadius(double lat, int zoom) {
  final mpp = satMetresPerPixel(lat, zoom);
  final maxR = zoom <= 17 ? 3 : 11;
  return (precacheRadiusMeters(zoom) / (mpp * 256)).ceil().clamp(1, maxR);
}

/// Result of a precache run.
typedef PrecacheResult = ({int fetched, int total});

/// Per-site cache coverage: how many of the precache URL set are on disk.
typedef SiteCacheCoverage = ({LaunchSite site, int cached, int total});

/// The exact tile URL set a precache run over [sites] would fetch (street +
/// satellite, zooms 13–19: ~1 km radius for 13–17, central ~1 km across for
/// 18–19 — plus the 3D satellite view's outer/mid/pad imagery and elevation
/// windows, so a pre-downloaded site opens the 3D terrain instantly in the
/// field). Shared by the downloader and the coverage probe so both agree on
/// what "cached" means.
List<String> precacheUrlsForSites(List<LaunchSite> sites) {
  final urls = <String>[];
  for (final site in sites) {
    for (var zoom = precacheMinZoom; zoom <= precacheMaxZoom; zoom++) {
      final r = precacheTileRadius(site.latitude, zoom);
      final cx = satTileX(site.longitude, zoom);
      final cy = satTileY(site.latitude, zoom);
      final n = 1 << zoom;
      for (var y = cy - r; y <= cy + r; y++) {
        if (y < 0 || y >= n) continue;
        for (var x = cx - r; x <= cx + r; x++) {
          final wx = ((x % n) + n) % n;
          urls.add(streetTileUrl(wx, y, zoom));
          urls.add(satelliteTileUrl(wx, y, zoom));
        }
      }
    }
    // Same disk cache the 3D view reads — pre-warms its exact tile set.
    urls.addAll(
        satTerrainTileUrls(site.latitude, site.longitude));
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
          // Placeholder "no data" tiles count as missing so the state
          // reflects usable imagery and the map falls back to parents.
          final hit = await cache.getTile(url);
          if (hit != null && isUsableTileBytes(hit.bytes)) cached++;
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

/// Downloads street + satellite tiles around [sites] (zooms 13–19, ~1 km
/// radius for 13–17 and central ~1 km across for 18–19, plus the 3D
/// terrain's imagery + elevation set) into flutter_map's disk cache.
/// Fire-and-forget friendly; skips tiles already cached and tolerates
/// offline (returns what it managed). Fetches in small parallel batches —
/// the set is hundreds of URLs per site, and sequential round-trips were
/// the bulk of the wait.
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
  void tick() => onProgress?.call(done, urls.length);
  try {
    const concurrency = 8;
    for (var i = 0; i < urls.length; i += concurrency) {
      final end =
          (i + concurrency < urls.length) ? i + concurrency : urls.length;
      await Future.wait([
        for (var j = i; j < end; j++)
          () async {
            try {
              if (await cache.getTile(urls[j]) == null) {
                final bytes = await fetchTileBytes(
                    client: client, Uri.parse(urls[j]));
                // Placeholders ("Map data not yet available") must not
                // poison the cache — the map falls back to lower-res
                // parents instead.
                if (bytes != null && isUsableTileBytes(bytes)) {
                  await putTileCached(urls[j], bytes);
                  fetched++;
                }
              }
            } catch (_) {
              // Skip failures — precaching is best-effort.
            }
            done++;
            tick();
          }(),
      ]);
    }
  } finally {
    client.close();
  }
  return (fetched: fetched, total: urls.length);
}

/// Rough tile count (both layers + the 3D terrain set) a precache run over
/// [sites] would fetch. Lets the UI warn before big downloads.
int precacheTileCount(List<LaunchSite> sites) {
  var total = 0;
  for (final site in sites) {
    for (var zoom = precacheMinZoom; zoom <= precacheMaxZoom; zoom++) {
      final r = precacheTileRadius(site.latitude, zoom);
      total += (2 * r + 1) * (2 * r + 1) * 2;
    }
    total += satTerrainTileUrls(site.latitude, site.longitude).length;
  }
  return total;
}
