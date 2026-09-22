/// Terrain shape for the dead reckoning ground clamp.
///
/// A single floor (lowest fix, one tile query) cannot follow hillsides: a
/// flight that drifts over a ridge would clamp to valley altitude. A list
/// of samples lets the estimator look up the floor at its *current*
/// predicted position instead.
library;

import 'package:meta/meta.dart';

/// One known terrain elevation (metres above mean sea level).
@immutable
class DeadReckoningTerrainSample {
  final double latitude;
  final double longitude;
  final double elevationMsl;

  const DeadReckoningTerrainSample({
    required this.latitude,
    required this.longitude,
    required this.elevationMsl,
  });
}
