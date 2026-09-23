import 'dart:math' as math;

/// Pure elevation / slippy-map math (data in, data out).
///
/// Extracted from `elevation_service` so both state/services and UI share
/// one implementation instead of duplicating tile math.
int elevationTileX(double lon, int zoom) {
  final n = 1 << zoom;
  return ((lon + 180) / 360 * n).floor().clamp(0, n - 1);
}

int elevationTileY(double lat, int zoom) {
  final n = 1 << zoom;
  final rad = lat * math.pi / 180;
  final y =
      ((1 - math.log(math.tan(rad) + 1 / math.cos(rad)) / math.pi) / 2 * n)
          .floor();
  return y.clamp(0, n - 1);
}

int elevationPixelX(double lon, int zoom, int tx) {
  final n = 1 << zoom;
  final exact = (lon + 180) / 360 * n - tx;
  return (exact * 256).floor().clamp(0, 255);
}

int elevationPixelY(double lat, int zoom, int ty) {
  final n = 1 << zoom;
  final rad = lat * math.pi / 180;
  final mercY = (1 - math.log(math.tan(rad) + 1 / math.cos(rad)) / math.pi) / 2 * n;
  return ((mercY - ty) * 256).floor().clamp(0, 255);
}

/// Decodes one Terrarium pixel to metres above sea level.
double terrariumHeight(int r, int g, int b) =>
    r * 256.0 + g + b / 256.0 - 32768.0;

/// AWS Terrain Tiles URL (Terrarium encoding, no API key).
String demTileUrl(int x, int y, int z) =>
    'https://s3.amazonaws.com/elevation-tiles-prod/terrarium/$z/$x/$y.png';

/// The z=12 tile key ("12/x/y") for coordinates.
String elevationTileKey(double lat, double lon) {
  const zoom = 12;
  return '$zoom/${elevationTileX(lon, zoom)}/${elevationTileY(lat, zoom)}';
}

/// Centre of a tile key from [elevationTileKey].
({double latitude, double longitude}) elevationTileCenter(String key) {
  final parts = key.split('/');
  final zoom = int.parse(parts[0]);
  final x = int.parse(parts[1]);
  final y = int.parse(parts[2]);
  final n = 1 << zoom;
  final longitude = (x + 0.5) / n * 360 - 180;
  final latRad = math.atan(_sinh(math.pi * (1 - 2 * (y + 0.5) / n)));
  return (latitude: latRad * 180 / math.pi, longitude: longitude);
}

double _sinh(double x) => (math.exp(x) - math.exp(-x)) / 2;
