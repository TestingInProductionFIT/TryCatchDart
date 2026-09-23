import 'package:serial/serial.dart';

/// Pure flight-extreme scans (data in, data out).
///
/// Extracted from `TelemetryState` getters so UI can compute peaks without
/// forcing a full-store rebuild, and so the logic is unit-testable.
double maxBaroAltitude(Iterable<TelemetryFrame> frames, double current) {
  var m = current;
  for (final f in frames) {
    if (f.baroAltitude > m) m = f.baroAltitude;
  }
  return m;
}

double maxTotalSpeed(Iterable<TelemetryFrame> frames) {
  var m = 0.0;
  for (final f in frames) {
    if (f.speedTotal > m) m = f.speedTotal;
  }
  return m;
}

double maxTotalAccel(Iterable<TelemetryFrame> frames) {
  var m = 0.0;
  for (final f in frames) {
    if (f.accelTotal > m) m = f.accelTotal;
  }
  return m;
}
