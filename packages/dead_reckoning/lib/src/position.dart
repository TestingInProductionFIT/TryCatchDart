/// Dead-reckoned position (WGS84 + MSL altitude).
library;

import 'package:meta/meta.dart';

/// Estimated position produced by [DeadReckoningEstimator].
@immutable
class DeadReckoningPosition {
  final double latitude;
  final double longitude;
  final double altitude;

  /// Estimate time (Unix epoch ms) — the sample time or, for extrapolated
  /// points, the wall-clock time the estimate was projected to.
  final int atMs;

  /// Predicted flight regime at [atMs]: `'climb'`, `'descent'`, `'level'` or
  /// `'landed'`, or `null` when unknown (e.g. positions built by hand in
  /// tests). Lets previews mark predicted transitions (apogee, chute open)
  /// without leaking in-outage truth.
  final String? regime;

  const DeadReckoningPosition({
    required this.latitude,
    required this.longitude,
    required this.altitude,
    required this.atMs,
    this.regime,
  });

  @override
  String toString() =>
      'DeadReckoningPosition(${latitude.toStringAsFixed(6)}, ${longitude.toStringAsFixed(6)}, ${altitude.toStringAsFixed(1)}m)';
}
