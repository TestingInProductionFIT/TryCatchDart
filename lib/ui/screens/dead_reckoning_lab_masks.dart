/// Pure outage-mask + tune-description helpers for the dead reckoning lab.
///
/// Extracted from `dead_reckoning_lab_tab.dart` so the window math is
/// testable without widgets. No behavior change: same tiers, fallbacks,
/// phase top-up, 45 s window, cap and sort order.
library;

import 'package:dead_reckoning/dead_reckoning.dart';
import 'package:serial/serial.dart' show FsmState, TelemetryFrame;

/// One-line summary of what differs from factory defaults.
String describeDeadReckoningTune(DeadReckoningTune tune) {
  if (tune == DeadReckoningTune.defaults) return 'factory defaults';
  final parts = <String>[];
  const defaults = DeadReckoningTune.defaults;
  if (tune.velocityScale != defaults.velocityScale) {
    parts.add('scale ${tune.velocityScale.toStringAsFixed(2)}');
  }
  if (!tune.accelerationTracking) {
    parts.add('no accel trend');
  }
  if (tune.horizontalDrag != defaults.horizontalDrag) {
    parts.add('drag ${tune.horizontalDrag.toStringAsFixed(3)}');
  }
  if (tune.velocityFilterAlpha != defaults.velocityFilterAlpha) {
    parts.add('smoothing ${tune.velocityFilterAlpha.toStringAsFixed(2)}');
  }
  if (tune.groundToleranceM != defaults.groundToleranceM) {
    parts.add('tolerance ${tune.groundToleranceM.toStringAsFixed(1)} m');
  }
  if (tune.maxHorizontalSpeed != null) {
    parts.add('horizontal ≤${tune.maxHorizontalSpeed!.toStringAsFixed(0)} m/s');
  }
  if (tune.maxVerticalSpeed != null) {
    parts.add('vertical ≤${tune.maxVerticalSpeed!.toStringAsFixed(0)} m/s');
  }
  if (tune.maxExtrapolationSeconds != null) {
    parts.add('horizon ${tune.maxExtrapolationSeconds!.toStringAsFixed(0)} s');
  }
  return parts.join(' · ');
}

/// Phases worth scoring outages in. Landed (and pad) need none: the
/// rocket stays put and only GPS drift is left to predict.
bool scorableLabPhase(String name) =>
    name == 'Ascent' || name == 'Apogee' || name == 'Parachute';

/// Short/medium/long outage tiers cycled over the period grid.
const labTierLengthsMs = [5000, 15000, 45000];

/// Max synthetic + top-up windows so the coordinate-descent search stays fast.
const labMaxMasks = 12;

String labScenarioAt(List<TelemetryFrame> frames, int ms) {
  TelemetryFrame? hit;
  for (final frame in frames) {
    if (frame.receivedAtMs > ms) break;
    hit = frame;
  }
  final state =
      hit == null ? FsmState.unknown : FsmState.fromId(hit.fsmStateId);
  return switch (state) {
    FsmState.ascent => 'Ascent',
    FsmState.apogee => 'Apogee',
    FsmState.parachute => 'Parachute',
    FsmState.landed => 'Landed',
    _ => 'Pad',
  };
}

/// Whether the recording changes flight phase inside [mask] (display
/// and mask-selection only — never fed to tuning).
bool labSpansTransition(
  DeadReckoningGapMask mask,
  List<TelemetryFrame> frames,
) {
  String? first;
  for (final frame in frames) {
    if (frame.receivedAtMs < mask.startMs) continue;
    if (frame.receivedAtMs > mask.endMs) break;
    final name = FsmState.fromId(frame.fsmStateId).label;
    first ??= name;
    if (name != first) return true;
  }
  return false;
}

/// Outage windows for the loaded flight, fully automatic: evenly spaced
/// synthetic windows sized to the flight, topped up so every flown
/// (scorable) phase gets at least one outage.
///
/// Windows cycle short/medium/long tiers (5 s, 15 s, 45 s): a long that
/// would swallow the next slot or run past the flight falls back to
/// 15 s, then 5 s, so short flights still get full coverage and long
/// flights preview all three lengths.
List<DeadReckoningGapMask> buildLabMasks(
  List<DeadReckoningSample> samples,
  List<TelemetryFrame> frames,
) {
  if (samples.length < 2) return const [];
  final durationMs =
      samples.last.receivedAtMs - samples.first.receivedAtMs;
  // One window per ~sixth of the flight, bounded so short flights still
  // get coverage and long ones stay fast to search.
  final periodMs = (durationMs / 6).round().clamp(15000, 60000);
  final endOfFlight = samples.last.receivedAtMs;
  final base = <DeadReckoningGapMask>[];
  var slot = 0;
  for (var cursor = samples.first.receivedAtMs + periodMs;
      cursor < endOfFlight;
      cursor += periodMs, slot++) {
    var lenMs = labTierLengthsMs[slot % labTierLengthsMs.length];
    // A long must neither swallow the next slot nor run past the
    // flight — fall back to shorter tiers instead of skipping the slot.
    if (lenMs > periodMs || cursor + lenMs > endOfFlight) {
      lenMs = 15000;
      if (lenMs > periodMs || cursor + lenMs > endOfFlight) {
        lenMs = 5000;
      }
      if (cursor + lenMs > endOfFlight) continue;
    }
    // Without frame phases nothing is known grounded: keep all.
    if (frames.isNotEmpty && !scorableLabPhase(labScenarioAt(frames, cursor))) {
      continue;
    }
    base.add(DeadReckoningGapMask(startMs: cursor, endMs: cursor + lenMs));
  }
  return withLabPhaseCoverage(base, samples, frames);
}

/// Adds one outage per scorable flight phase that the uniform [base]
/// masks miss, fitted inside the phase so it scores and previews
/// (15 s preferred, shrinking to fit short phases like apogee — a 3 s
/// outage still scores). Then ensures a 45 s window exists when the
/// flight can fit one, placed inside the longest scorable phase, so
/// the carousel always shows a long outage next to the short ones.
/// Grounded phases are skipped outright. Sorted, de-duplicated, capped
/// so the search stays fast.
List<DeadReckoningGapMask> withLabPhaseCoverage(
  List<DeadReckoningGapMask> base,
  List<DeadReckoningSample> samples,
  List<TelemetryFrame> frames,
) {
  if (frames.isEmpty || samples.isEmpty) return base;
  final endOfFlight = samples.last.receivedAtMs;
  // Phase segments from consecutive same-label frames.
  final segments = <({String name, int startMs, int endMs})>[];
  var curName = FsmState.fromId(frames.first.fsmStateId).label;
  var curStart = frames.first.receivedAtMs;
  for (var i = 1; i < frames.length; i++) {
    final name = FsmState.fromId(frames[i].fsmStateId).label;
    if (name != curName) {
      segments.add(
          (name: curName, startMs: curStart, endMs: frames[i].receivedAtMs));
      curName = name;
      curStart = frames[i].receivedAtMs;
    }
  }
  segments.add(
      (name: curName, startMs: curStart, endMs: frames.last.receivedAtMs));
  final masks = [...base];
  bool overlaps(int a, int b) =>
      masks.any((m) => a < m.endMs && b > m.startMs);
  for (final seg in segments) {
    if (masks.length >= labMaxMasks) break;
    if (seg.endMs - seg.startMs < 2000) continue;
    // Raw FSM labels match the display names for the flying phases.
    if (!scorableLabPhase(seg.name)) continue;
    if (masks.any((m) => m.startMs >= seg.startMs && m.startMs < seg.endMs)) {
      continue;
    }
    final start = seg.startMs + 1000;
    // Fit inside the phase; skip when even a 1 s window won't fit.
    // Stay strictly inside: a window touching the next phase's first
    // frame would span a transition and be excluded from tuning.
    final fullEnd = start + 15000;
    final end = fullEnd < seg.endMs ? fullEnd : seg.endMs - 1;
    if (end - start < 1000 || end > endOfFlight || overlaps(start, end)) {
      continue;
    }
    masks.add(DeadReckoningGapMask(startMs: start, endMs: end));
  }
  // One 45 s window when the flight can fit it, inside the longest
  // scorable phase that has room — short flights simply skip it.
  if (masks.length < labMaxMasks &&
      !masks.any((m) => m.endMs - m.startMs >= 30000) &&
      endOfFlight - samples.first.receivedAtMs >= 120000) {
    final roomy = [...segments]
      ..sort(
          (a, b) => (b.endMs - b.startMs).compareTo(a.endMs - a.startMs));
    for (final seg in roomy) {
      if (!scorableLabPhase(seg.name)) continue;
      if (seg.endMs - seg.startMs < 47000) continue;
      final start = seg.startMs + 1000;
      final end = start + 45000;
      if (end > seg.endMs || end > endOfFlight || overlaps(start, end)) {
        continue;
      }
      masks.add(DeadReckoningGapMask(startMs: start, endMs: end));
      break;
    }
  }
  masks.sort((a, b) => a.startMs.compareTo(b.startMs));
  return masks;
}

/// Generic stride decimation keeping the last point: replaces the
/// duplicated `_decimateEnu` / `_decimateRegimes` pair.
List<T> decimateLab<T>(List<T> points, int max) {
  if (points.length <= max) return points;
  final stride = (points.length / max).ceil();
  final kept = <T>[];
  for (var i = 0; i < points.length; i += stride) {
    kept.add(points[i]);
  }
  if (kept.last != points.last) kept.add(points.last);
  return kept;
}

/// Comparison-row formatters: `null` renders as an em dash.
String formatLabMeanM(double? value) =>
    value == null ? '—' : '${value.toStringAsFixed(0)} m';

String formatLabVerticalM(double? value) =>
    value == null ? '—' : '${value.toStringAsFixed(1)} m';
