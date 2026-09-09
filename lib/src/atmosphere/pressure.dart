/// Standard-atmosphere static pressure helpers.
////
/// The wire format carries barometric *altitude*, not raw pressure, so the
/// pressure graph inverts the same ISA troposphere model the flight software
/// uses to turn its pressure sensor into altitude. Anchored at the selected
/// launch site's MSL altitude this recovers the real sensor curve (e.g. the
/// imported CRC flight: 968.7 hPa on the pad, ~913.3 hPa at apogee).
library;

import 'dart:math' as math;

/// ISA sea-level reference pressure in pascals.
const double seaLevelPressurePa = 101325.0;

/// Static pressure (Pa) at [mslM] metres above mean sea level, ISA
/// troposphere: P0·(1 − L·h/T0)^5.25588. Returns 0 above the model's
/// ceiling instead of NaN.
double pressurePaFromMsl(double mslM) {
  final t = 1 - 0.0065 * mslM / 288.15;
  if (t <= 0) return 0;
  return seaLevelPressurePa * math.pow(t, 5.25588);
}

/// Static pressure (Pa) for a barometric AGL reading, given the launch
/// site's MSL altitude. Defaults to a sea-level site when none is selected.
double pressurePaFromBaro(double baroAglM, {double siteMslM = 0}) =>
    pressurePaFromMsl(siteMslM + baroAglM);
