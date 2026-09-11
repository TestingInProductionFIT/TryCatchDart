import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_map/flutter_map.dart';

import './tile_io.dart';

/// Offline-first tile provider with lower-resolution fallback.
///
/// Lookup order per tile:
/// 1. exact tile from flutter_map's disk cache,
/// 2. closest cached parent (up to [maxFallbackLevels] up), cropped to the
///    child's quadrant and upscaled to 256 px,
/// 3. network fetch of the exact tile (cached on success).
///
/// This keeps the field map usable when the high-detail levels (18–19) were
/// only partly downloaded, or when Esri has no native tile at that level:
/// instead of a blank hole the map shows the best cached lower-res imagery.
/// Pure coordinate math ([wrapX], [parentTileCoords]) is unit-testable.
class OfflineFallbackTileProvider extends TileProvider {
  /// Esri style, e.g. `World_Street_Map` / `World_Imagery`.
  final String style;

  /// How many levels up to look for a cached parent.
  final int maxFallbackLevels;

  OfflineFallbackTileProvider({
    required this.style,
    this.maxFallbackLevels = 4,
    super.headers,
  });

  @override
  bool get supportsCancelLoading => true;

  @override
  ImageProvider getImageWithCancelLoadingSupport(
    TileCoordinates coordinates,
    TileLayer options,
    Future<void> cancelLoading,
  ) {
    final z = coordinates.z;
    final wx = wrapX(coordinates.x, z);
    return OfflineFallbackTileImage(
      url: esriTileUrl(style, wx, coordinates.y, z),
      style: style,
      x: coordinates.x,
      y: coordinates.y,
      z: z,
      maxFallbackLevels: maxFallbackLevels,
    );
  }
}

/// Wraps [x] into 0..2^zoom-1 (tiles repeat around the antimeridian).
int wrapX(int x, int zoom) {
  final n = 1 << zoom;
  return ((x % n) + n) % n;
}

/// Parent tile [levelsUp] levels above ([x], [y], [z]).
({int x, int y, int z}) parentTileCoords(
  int x,
  int y,
  int z,
  int levelsUp,
) {
  final pz = z - levelsUp;
  final wx = wrapX(x, z);
  return (x: wrapX(wx >> levelsUp, pz), y: y >> levelsUp, z: pz);
}

/// Quadrant of the parent occupied by the child: [scale] is the parent split
/// (2^levels), ([qx], [qy]) the child's cell in it.
({int qx, int qy, int scale}) quadrantForChild(
  int x,
  int y,
  int z,
  int px,
  int py,
  int pz,
) {
  final scale = 1 << (z - pz);
  final wx = wrapX(x, z);
  return (qx: wx - (px << (z - pz)), qy: y - (py << (z - pz)), scale: scale);
}

/// In-memory LRU for [cropParentTile] results.
///
/// Zooming in/out over the same area re-requests the same child crops on
/// every pass; without this each revisit repeats a disk read, an image
/// decode, a GPU crop round-trip and a PNG re-encode — visible as tile
/// flicker while the fallback recomputes. Cropped PNGs are small (tens of
/// KB), so a modest entry cap bounds memory to a few MB.
class CroppedTileCache {
  /// Maximum entries held; least-recently-used evicted first.
  final int capacity;

  final _entries = <String, Uint8List>{}; // insertion-ordered

  CroppedTileCache({this.capacity = 128}) : assert(capacity > 0);

  int get length => _entries.length;

  Uint8List? get(String key) {
    final hit = _entries.remove(key);
    if (hit == null) return null;
    // Re-insert to mark most-recently-used.
    _entries[key] = hit;
    return hit;
  }

  void put(String key, Uint8List bytes) {
    _entries.remove(key);
    _entries[key] = bytes;
    while (_entries.length > capacity) {
      _entries.remove(_entries.keys.first);
    }
  }

  @visibleForTesting
  void clear() => _entries.clear();
}

/// Process-wide crop cache consulted by [cropParentTile].
final croppedTileCache = CroppedTileCache();

/// Cache key for a child crop: coordinates plus parent identity (length +
/// FNV-1a, so a refreshed parent tile can't serve a stale crop).
String _cropCacheKey(
  Uint8List parentBytes,
  int x,
  int y,
  int z,
  int px,
  int py,
  int pz,
) {
  var hash = 0x811C9DC5;
  for (var i = 0; i < parentBytes.length; i++) {
    hash ^= parentBytes[i];
    hash = (hash * 0x01000193) & 0xFFFFFFFF;
  }
  return '$x/$y/$z-$px/$py/$pz-${parentBytes.length}-$hash';
}

/// Crops the quadrant of [parentBytes] occupied by child ([x], [y], [z])
/// with parent ([px], [py], [pz]) and upscales it to 256×256 PNG.
/// Returns `null` when undecodable or out of range.
///
/// Results are memoized in [croppedTileCache]: zoom oscillation over cached
/// imagery re-serves the same crops from memory instead of recomputing them
/// (and flashing gaps meanwhile).
Future<Uint8List?> cropParentTile(
  Uint8List parentBytes,
  int x,
  int y,
  int z,
  int px,
  int py,
  int pz,
) async {
  try {
    if (pz < 0 || pz >= z) return null;
    final levels = z - pz;
    if (levels <= 0 || levels > 8) return null;
    final quad = quadrantForChild(x, y, z, px, py, pz);
    if (quad.qx < 0 ||
        quad.qy < 0 ||
        quad.qx >= quad.scale ||
        quad.qy >= quad.scale) {
      return null;
    }
    final key = _cropCacheKey(parentBytes, x, y, z, px, py, pz);
    final hit = croppedTileCache.get(key);
    if (hit != null) return hit;
    final codec = await ui.instantiateImageCodec(parentBytes);
    final frame = await codec.getNextFrame();
    final tile = frame.image;
    try {
      final src = Rect.fromLTWH(
        quad.qx * tile.width / quad.scale,
        quad.qy * tile.height / quad.scale,
        tile.width / quad.scale,
        tile.height / quad.scale,
      );
      final recorder = ui.PictureRecorder();
      final canvas = ui.Canvas(recorder);
      canvas.drawImageRect(
        tile,
        src,
        const Rect.fromLTWH(0, 0, 256, 256),
        ui.Paint()..filterQuality = ui.FilterQuality.medium,
      );
      final picture = recorder.endRecording();
      final out = await picture.toImage(256, 256);
      picture.dispose();
      try {
        final data = await out.toByteData(format: ui.ImageByteFormat.png);
        final bytes = data?.buffer.asUint8List();
        if (bytes != null) croppedTileCache.put(key, bytes);
        return bytes;
      } finally {
        out.dispose();
      }
    } finally {
      tile.dispose();
    }
  } catch (_) {
    return null;
  }
}

/// Image provider used by [OfflineFallbackTileProvider]. See its docs for
/// the lookup order.
class OfflineFallbackTileImage
    extends ImageProvider<OfflineFallbackTileImage> {
  final String url;
  final String style;
  final int x;
  final int y;
  final int z;
  final int maxFallbackLevels;

  const OfflineFallbackTileImage({
    required this.url,
    required this.style,
    required this.x,
    required this.y,
    required this.z,
    this.maxFallbackLevels = 4,
  });

  @override
  ImageStreamCompleter loadImage(
    OfflineFallbackTileImage key,
    ImageDecoderCallback decode,
  ) {
    final chunkEvents = StreamController<ImageChunkEvent>();
    return MultiFrameImageStreamCompleter(
      codec: _load(key, decode).then(
        (codec) {
          unawaited(chunkEvents.close());
          return codec;
        },
        onError: (Object e, StackTrace s) {
          unawaited(chunkEvents.close());
          throw e;
        },
      ),
      chunkEvents: chunkEvents.stream,
      scale: 1,
      debugLabel: key.url,
      informationCollector: () => [
        DiagnosticsProperty('URL', url),
        DiagnosticsProperty('Current provider', key),
      ],
    );
  }

  Future<ui.Codec> _load(
    OfflineFallbackTileImage key,
    ImageDecoderCallback decode,
  ) async {
    void evict() =>
        scheduleMicrotask(() => PaintingBinding.instance.imageCache.evict(key));
    Future<ui.Codec> decodeBytes(Uint8List bytes) =>
        ui.ImmutableBuffer.fromUint8List(bytes).then(decode);

    final cache = BuiltInMapCachingProvider.getOrCreateInstance();

    // 1. Exact cached tile (placeholders count as missing so a cached
    // "Map data not yet available" falls back to the parent, not the screen).
    if (cache.isSupported) {
      try {
        final hit = await cache.getTile(url);
        if (hit != null &&
            hit.bytes.isNotEmpty &&
            isUsableTileBytes(hit.bytes)) {
          try {
            return await decodeBytes(hit.bytes);
          } catch (_) {
            // Corrupt entry — fall through to parent/network below.
          }
        }
      } catch (_) {
        // Cache read failure — keep going.
      }

      // 2. Closest cached parent, cropped to our quadrant.
      for (var levels = 1; levels <= maxFallbackLevels; levels++) {
        final pz = z - levels;
        if (pz < 0) break;
        final p = parentTileCoords(x, y, z, levels);
        final n = 1 << pz;
        if (p.y < 0 || p.y >= n) continue;
        final parentUrl = esriTileUrl(style, p.x, p.y, pz);
        try {
          final hit = await cache.getTile(parentUrl);
          if (hit == null ||
              hit.bytes.isEmpty ||
              !isUsableTileBytes(hit.bytes)) {
            continue;
          }
          final cropped =
              await cropParentTile(hit.bytes, x, y, z, p.x, p.y, pz);
          if (cropped != null) {
            // Warm the exact tile in the background so the next view is
            // sharp when online.
            unawaited(_warmExact(url));
            return await decodeBytes(cropped);
          }
        } catch (_) {
          continue;
        }
      }
    }

    // 3. Network fetch of the exact tile. Placeholders are rejected so a
    // missing detail zoom falls through to the error below (and the map
    // keeps the parent tile) instead of caching "Map data not yet
    // available".
    try {
      final bytes = await fetchTileBytes(Uri.parse(url));
      if (bytes != null && isUsableTileBytes(bytes)) {
        await putTileCached(url, bytes);
        try {
          return await decodeBytes(bytes);
        } catch (_) {
          // Fall through to the error below.
        }
      }
    } catch (_) {
      // Fall through to the error below.
    }

    evict();
    throw StateError('tile unavailable: $url');
  }

  /// Best-effort background fetch so serving a blurry parent still warms the
  /// exact tile for the next view. Never throws.
  static Future<void> _warmExact(String url) async {
    try {
      final bytes = await fetchTileBytes(Uri.parse(url));
      if (bytes != null && isUsableTileBytes(bytes)) {
        await putTileCached(url, bytes);
      }
    } catch (_) {
      // Warming is opportunistic.
    }
  }

  @override
  SynchronousFuture<OfflineFallbackTileImage> obtainKey(
    ImageConfiguration configuration,
  ) =>
      SynchronousFuture(this);

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is OfflineFallbackTileImage && url == other.url);

  @override
  int get hashCode => url.hashCode;
}
