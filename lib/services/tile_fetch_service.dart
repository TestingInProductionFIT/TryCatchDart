import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_map/flutter_map.dart'
    show BuiltInMapCachingProvider, CachedMapTileMetadata;

import '../core/app_config.dart';
import '../ui/tiles/shared/tile_io.dart'
    show fetchTileBytes, isUsableTileBytes, putTileCached;

/// Shared tile network + disk-cache access (layer 3 service).
///
/// `elevation_service`, `map_tiles` and `satellite_ground` must go through
/// here so User-Agent, timeouts, validation and TTL stay in one place.
/// Pure URL builders stay in `tile_io`; this owns the I/O.
abstract final class TileFetchService {
  /// Cached-or-network fetch of a raster tile. Returns `null` on any
  /// failure, placeholder, or non-image body.
  static Future<Uint8List?> fetchCachedTile(String url) async {
    final cache = BuiltInMapCachingProvider.getOrCreateInstance();
    if (cache.isSupported) {
      try {
        final hit = await cache.getTile(url);
        if (hit != null &&
            hit.bytes.isNotEmpty &&
            isUsableTileBytes(hit.bytes)) {
          return hit.bytes;
        }
      } catch (_) {}
    }
    final bytes = await fetchTileBytes(Uri.parse(url));
    if (bytes == null || !isUsableTileBytes(bytes)) return null;
    await putTileCached(url, bytes);
    return bytes;
  }

  /// Raw network fetch with shared client (for precache loops).
  static Future<Uint8List?> fetchNetwork(Uri url, {HttpClient? client}) =>
      fetchTileBytes(url, client: client);

  static Duration get cacheTtl => AppConfig.tileCacheTtl;

  static CachedMapTileMetadata cacheMetadata() => CachedMapTileMetadata(
        staleAt: DateTime.timestamp().add(AppConfig.tileCacheTtl),
        lastModified: null,
        etag: null,
      );
}
