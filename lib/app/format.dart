// Shared human formatting helpers (durations as m:ss).

/// Milliseconds → `m:ss` (e.g. 95000 → `1:35`).
String formatMinSec(int ms) {
  final m = ms ~/ 60000;
  final s = (ms % 60000) ~/ 1000;
  return '$m:${s.toString().padLeft(2, '0')}';
}
