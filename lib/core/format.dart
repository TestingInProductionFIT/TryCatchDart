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

/// Metres → `850 m` / `1.24 km` (kilometres past 1000 m).
String formatDistanceM(double metres) => metres >= 1000
    ? '${(metres / 1000).toStringAsFixed(2)} km'
    : '${metres.toStringAsFixed(0)} m';

/// Metres → `850 m from launch site` / `1.24 km from launch site`.
String formatDistanceFrom(double metres, String place) =>
    '${formatDistanceM(metres)} from $place';

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

/// Duration since the last packet → `850 ms ago` / `3.2 s ago` / `2m 5s ago`.
String formatPacketAge(Duration d) {
  final s = d.inMilliseconds / 1000.0;
  if (s < 1.0) return '${d.inMilliseconds} ms ago';
  if (s < 60) return '${s.toStringAsFixed(1)} s ago';
  return '${d.inMinutes}m ${d.inSeconds % 60}s ago';
}

/// Duration → `45 s in state` / `3 m 07 s in state`.
String formatTimeInState(Duration d) {
  final seconds = d.inMilliseconds / 1000;
  final m = seconds ~/ 60;
  final s = (seconds % 60).toStringAsFixed(0).padLeft(2, '0');
  return '${m > 0 ? '$m m ' : ''}$s s in state';
}
