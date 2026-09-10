/// Geodesy helpers shared by the map, stats and estimation modules.
library;

import 'dart:math' as math;

/// Metres per degree of latitude (WGS84 mean). Mirrored by the mock flight
/// simulator in the serial package (which cannot import app code) — keep
/// in sync.
const double metresPerDegreeLat = 111320;

/// Great-circle distance between two WGS84 points in metres (haversine).
double haversineDistanceM(
  double lat1,
  double lon1,
  double lat2,
  double lon2,
) {
  final dLat = _rad(lat2 - lat1);
  final dLon = _rad(lon2 - lon1);
  final a = math.sin(dLat / 2) * math.sin(dLat / 2) +
      math.cos(_rad(lat1)) *
          math.cos(_rad(lat2)) *
          math.sin(dLon / 2) *
          math.sin(dLon / 2);
  return 2 * 6371000 * math.asin(math.sqrt(a));
}

/// Adds a north/east offset (metres) to a WGS84 point using a flat-earth
/// approximation — accurate to well under a metre for the few-kilometre
/// ranges of a model rocket flight.
({double latitude, double longitude}) offsetLatLon(
  double latitude,
  double longitude, {
  required double northM,
  required double eastM,
}) {
  return (
    latitude: latitude + northM / metresPerDegreeLat,
    longitude: longitude + eastM / (metresPerDegreeLat * math.cos(_rad(latitude))),
  );
}

double _rad(double deg) => deg * math.pi / 180;
