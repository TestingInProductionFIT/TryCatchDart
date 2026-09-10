// Shared human formatting helpers (durations as m:ss).

/// Milliseconds → `m:ss` (e.g. 95000 → `1:35`).
String formatMinSec(int ms) {
  final m = ms ~/ 60000;
  final s = (ms % 60000) ~/ 1000;
  return '$m:${s.toString().padLeft(2, '0')}';
}

/// Metres → `12 m` / `12.3 m` (no decimals past 100 m, `—` when null).
String formatAltitudeM(double? m) => m == null
    ? '—'
    : '${m.toStringAsFixed(m.abs() >= 100 ? 0 : 1)} m';

/// WGS84 pair with degree marks (`50.07550°, 14.43780°`).
String formatLatLon(double lat, double lon) =>
    '${lat.toStringAsFixed(5)}°, ${lon.toStringAsFixed(5)}°';

/// Plain paste format — Google Maps search takes it as-is.
String formatLatLonPlain(double lat, double lon) =>
    '${lat.toStringAsFixed(6)}, ${lon.toStringAsFixed(6)}';

/// Date → `2026-09-09 14:03` (local).
String formatDateTime(DateTime dt) =>
    '${dt.year}-${dt.month.toString().padLeft(2, '0')}-'
    '${dt.day.toString().padLeft(2, '0')} '
    '${dt.hour.toString().padLeft(2, '0')}:'
    '${dt.minute.toString().padLeft(2, '0')}';

/// Duration → `45 s in state` / `3 m 07 s in state`.
String formatTimeInState(Duration d) {
  final seconds = d.inMilliseconds / 1000;
  final m = seconds ~/ 60;
  final s = (seconds % 60).toStringAsFixed(0).padLeft(2, '0');
  return '${m > 0 ? '$m m ' : ''}$s s in state';
}
