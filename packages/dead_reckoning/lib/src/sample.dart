/// Plain input sample for the dead reckoning estimator.
///
/// Deliberately decoupled from the wire format (`TelemetryFrame` lives in
/// `package:serial` and this package must not depend on it): the app maps
/// each decoded frame to a [DeadReckoningSample] via a thin adapter and
/// feeds samples in chronological order.
library;

import 'package:meta/meta.dart';

/// One velocity/position snapshot fed to [DeadReckoningEstimator].
@immutable
class DeadReckoningSample {
  /// Wall-clock time the sample was observed (Unix epoch, ms).
  final int receivedAtMs;

  /// WGS84 latitude in degrees. Only meaningful when [hasFix] is true.
  final double latitude;

  /// WGS84 longitude in degrees. Only meaningful when [hasFix] is true.
  final double longitude;

  /// GPS-reported altitude in metres above mean sea level.
  /// Only meaningful when [hasFix] is true.
  final double gpsAltitude;

  /// North velocity in m/s (NED frame).
  final double velocityNorth;

  /// East velocity in m/s (NED frame).
  final double velocityEast;

  /// Down velocity in m/s (NED frame, positive towards the ground).
  final double velocityDown;

  /// Whether the GPS reported a position fix for this sample.
  final bool hasFix;

  const DeadReckoningSample({
    required this.receivedAtMs,
    this.latitude = 0,
    this.longitude = 0,
    this.gpsAltitude = 0,
    this.velocityNorth = 0,
    this.velocityEast = 0,
    this.velocityDown = 0,
    this.hasFix = true,
  });
}
