/// Offline scoring of a dead reckoning tune against recorded samples.
///
/// The lab replays a recording's samples through [DeadReckoningEstimator]
/// with fixes hidden inside each [DeadReckoningGapMask] window and compares
/// the predicted position at the window end against the first real fix at
/// or after it. Error metric: horizontal haversine distance (plus vertical
/// difference), i.e. the difference between predicted and actual location.
///
/// ### Wind / direction bias
/// Every real flight carries wind from one particular direction, which says
/// nothing about the rocket — a tune must not be rewarded for fitting that
/// one direction. Use [evaluateDeadReckoningRotationInvariant] for tuning:
/// it replays rotated copies of the recording (see
/// [rotatedDeadReckoningSamples]) and averages the error over all headings,
/// so a direction-specific overfit scores no better than the baseline.
library;

import 'dart:math' as math;

import './estimator.dart';
import './geo.dart';
import './position.dart';
import './sample.dart';
import './terrain.dart';
import './tune.dart';

/// Reference window for gap weighting: a 15 s outage weighs exactly 1.
const double kGapReferenceMs = 15000.0;

/// Clamp for [deadReckoningGapWeight] so slivers and multi-minute windows
/// cannot rig the search.
const double kGapWeightMin = 0.25;
const double kGapWeightMax = 4.0;

/// A window in which GPS fixes are hidden from the estimator (ms, relative
/// to the same clock as the samples).
class DeadReckoningGapMask {
  /// Mask start (inclusive, sample clock ms).
  final int startMs;

  /// Mask end (exclusive, sample clock ms).
  final int endMs;

  const DeadReckoningGapMask({required this.startMs, required this.endMs})
      : assert(endMs > startMs);
}

/// Per-gap scoring result.
class DeadReckoningGapScore {
  /// Mask that produced this score.
  final DeadReckoningGapMask mask;

  /// Estimator prediction at the first real fix at/after the mask end.
  /// `null` when the estimator was never anchored or no later fix exists.
  final DeadReckoningPosition? predicted;

  /// Actual fix the prediction is compared against (`null` when no later
  /// fix exists — the gap is then unscored).
  final DeadReckoningSample? actual;

  const DeadReckoningGapScore({
    required this.mask,
    required this.predicted,
    required this.actual,
  });

  /// Whether the gap produced a comparable prediction/actual pair.
  bool get scored => predicted != null && actual != null;

  /// Horizontal error in metres (haversine), or `null` when unscored.
  double? get horizontalErrorM {
    final prediction = predicted;
    final truth = actual;
    if (!scored) return null;
    return haversineDistanceM(
      truth!.latitude,
      truth.longitude,
      prediction!.latitude,
      prediction.longitude,
    );
  }

  /// Signed vertical error in metres (predicted minus actual).
  double? get verticalErrorM {
    final prediction = predicted;
    final truth = actual;
    if (!scored) return null;
    return prediction!.altitude - truth!.gpsAltitude;
  }
}

/// Weight of one gap in the tuning objective: shorter windows pin down the
/// per-second drift rate, while long outages accumulate large absolute
/// errors that would otherwise dominate an unweighted mean. Normalized so
/// a 15 s window weighs 1 (5 s → 3, 45 s → 1/3), clamped so degenerate
/// 1 s slivers and multi-minute windows cannot rig the search.
double deadReckoningGapWeight(DeadReckoningGapMask mask) {
  final durationMs = mask.endMs - mask.startMs;
  if (durationMs <= 0) return 1;
  return (kGapReferenceMs / durationMs).clamp(kGapWeightMin, kGapWeightMax);
}

double? _meanOf(List<double> values) {
  if (values.isEmpty) return null;
  return values.reduce((a, b) => a + b) / values.length;
}

/// Whole-run scoring summary.
class DeadReckoningEvaluation {
  /// Per-gap scores in mask order.
  final List<DeadReckoningGapScore> gaps;

  const DeadReckoningEvaluation(this.gaps);

  /// Gaps that produced a comparable pair.
  List<DeadReckoningGapScore> get scored =>
      [for (final gap in gaps) if (gap.scored) gap];

  /// Duration-weighted mean horizontal error (m) — the headline tuning
  /// objective. Short windows weigh more per second of outage (see
  /// [deadReckoningGapWeight]), so one 45 s window cannot outvote three
  /// 5 s windows. `null` when no gap scored.
  double? get weightedMeanHorizontalErrorM {
    var sumW = 0.0;
    var sumWE = 0.0;
    for (final gap in gaps) {
      final error = gap.horizontalErrorM;
      if (error == null) continue;
      final w = deadReckoningGapWeight(gap.mask);
      sumW += w;
      sumWE += w * error;
    }
    return sumW == 0 ? null : sumWE / sumW;
  }

  /// Duration-weighted vertical RMSE (m) — same [deadReckoningGapWeight]
  /// weighting as the horizontal objective. `null` when unscored.
  double? get weightedVerticalRmseM {
    var sumW = 0.0;
    var sumWE2 = 0.0;
    for (final gap in gaps) {
      final error = gap.verticalErrorM;
      if (error == null) continue;
      final w = deadReckoningGapWeight(gap.mask);
      sumW += w;
      sumWE2 += w * error * error;
    }
    return sumW == 0 ? null : math.sqrt(sumWE2 / sumW);
  }
}

/// Fresh estimator with [tune] and [terrain] applied. Public so the
/// optimizer and the preview builder share one construction path.
DeadReckoningEstimator freshEstimatorForEval(
  DeadReckoningTune tune,
  List<DeadReckoningTerrainSample> terrain,
) {
  final estimator = DeadReckoningEstimator(tune: tune);
  if (terrain.isNotEmpty) estimator.setTerrainSamples(terrain);
  return estimator;
}

/// Copy of [sample] with the fix hidden but velocity and timing kept —
/// the unit the masked replay feeds the estimator inside a gap.
DeadReckoningSample hideFixForEval(DeadReckoningSample sample) {
  return DeadReckoningSample(
    receivedAtMs: sample.receivedAtMs,
    velocityNorth: sample.velocityNorth,
    velocityEast: sample.velocityEast,
    velocityDown: sample.velocityDown,
    hasFix: false,
  );
}

/// Rotates the horizontal plane of [samples] counter-clockwise by [angleRad]
/// around the first fix (positions and NED horizontal velocities together).
///
/// Timestamps, altitudes, vertical velocity and fix flags are untouched, so
/// gap masks (which are time-based) apply unchanged to the rotated copy.
/// Used to cancel wind direction out of tuning: the same flight replayed on
/// every heading must score the same for a direction-neutral tune.
List<DeadReckoningSample> rotatedDeadReckoningSamples(
  List<DeadReckoningSample> samples,
  double angleRad,
) {
  if (samples.isEmpty) return const [];
  final origin = samples.firstWhere(
    (sample) => sample.hasFix,
    orElse: () => samples.first,
  );
  final cosLat = math.cos(origin.latitude * math.pi / 180);
  final cos = math.cos(angleRad);
  final sin = math.sin(angleRad);

  (double, double) rotate(double northM, double eastM) =>
      (northM * cos - eastM * sin, northM * sin + eastM * cos);

  return [
    for (final sample in samples)
      (() {
        final northM =
            (sample.latitude - origin.latitude) * metresPerDegreeLat;
        final eastM = (sample.longitude - origin.longitude) *
            metresPerDegreeLat *
            cosLat;
        final (rotN, rotE) = rotate(northM, eastM);
        final moved = offsetLatLon(
          origin.latitude,
          origin.longitude,
          northM: rotN,
          eastM: rotE,
        );
        final (rotVelN, rotVelE) =
            rotate(sample.velocityNorth, sample.velocityEast);
        return DeadReckoningSample(
          receivedAtMs: sample.receivedAtMs,
          latitude: moved.latitude,
          longitude: moved.longitude,
          gpsAltitude: sample.gpsAltitude,
          velocityNorth: rotVelN,
          velocityEast: rotVelE,
          velocityDown: sample.velocityDown,
          hasFix: sample.hasFix,
        );
      })(),
  ];
}

/// `n` evenly spaced heading copies of [samples] (`k * 2π / n`), shared by
/// evaluation and optimization so the rotation math lives in one place.
List<List<DeadReckoningSample>> rotatedCopies(
  List<DeadReckoningSample> samples,
  int n,
) {
  assert(n > 0);
  return [
    for (var k = 0; k < n; k++)
      rotatedDeadReckoningSamples(samples, k * 2 * math.pi / n),
  ];
}

/// Rotation-invariant scoring summary: one [DeadReckoningEvaluation] per
/// replayed heading plus aggregates over headings.
class DeadReckoningRotationInvariantEvaluation {
  /// Per-heading evaluations, index `k` replayed at `k * 2π / n`.
  final List<DeadReckoningEvaluation> perRotation;

  const DeadReckoningRotationInvariantEvaluation(this.perRotation);

  /// Mean of per-heading duration-weighted means (m) — the headline
  /// tuning objective. `null` when no heading scored.
  double? get weightedMeanHorizontalErrorM =>
      _meanOf([for (final e in perRotation) e.weightedMeanHorizontalErrorM]
          .whereType<double>()
          .toList());
}

/// Scores [tune] on [rotationCount] evenly spaced headings of the recording.
///
/// Each replay rotates the samples (see [rotatedDeadReckoningSamples]) and
/// evaluates the same time-based [masks]. Averaging over headings cancels
/// the recording's wind direction: a tune that only fits the flown heading
/// pays the same error on every other heading.
///
/// The default of 8 headings (every 45°) balances bias cancellation against
/// compute cost; each replay is O(samples × masks) like [evaluateDeadReckoning].
DeadReckoningRotationInvariantEvaluation
    evaluateDeadReckoningRotationInvariant({
  required List<DeadReckoningSample> samples,
  required DeadReckoningTune tune,
  required List<DeadReckoningGapMask> masks,
  int rotationCount = 8,
  List<DeadReckoningTerrainSample> terrain = const [],
}) {
  assert(rotationCount > 0);
  return evaluateRotatedSampleSets(
    rotated: rotatedCopies(samples, rotationCount),
    tune: tune,
    masks: masks,
    terrain: terrain,
  );
}

/// Scores [tune] on pre-rotated sample sets (see
/// [rotatedDeadReckoningSamples]). Same as
/// [evaluateDeadReckoningRotationInvariant] but skips re-rotating, so
/// optimizers can rotate once and score many candidates.
DeadReckoningRotationInvariantEvaluation evaluateRotatedSampleSets({
  required List<List<DeadReckoningSample>> rotated,
  required DeadReckoningTune tune,
  required List<DeadReckoningGapMask> masks,
  List<DeadReckoningTerrainSample> terrain = const [],
}) {
  return DeadReckoningRotationInvariantEvaluation([
    for (final samples in rotated)
      evaluateDeadReckoning(
        samples: samples,
        tune: tune,
        masks: masks,
        terrain: terrain,
      ),
  ]);
}
///
/// Scores [tune] by replaying [samples] (chronological) through a fresh
/// estimator with fixes hidden inside each mask.
///
/// For every mask the estimator is fed masked samples (fix forced off
/// inside the window; samples outside pass through untouched, including
/// extrapolation between samples via [DeadReckoningEstimator.extrapolate]
/// so wall-clock gaps behave like the live ticker). The prediction is read
/// at the first real fix at/after the mask end and compared against it.
///
/// [terrain] is applied to every estimator so the ground clamp follows the
/// terrain shape instead of a single floor.
DeadReckoningEvaluation evaluateDeadReckoning({
  required List<DeadReckoningSample> samples,
  required DeadReckoningTune tune,
  required List<DeadReckoningGapMask> masks,
  List<DeadReckoningTerrainSample> terrain = const [],
}) {
  final scores = <DeadReckoningGapScore>[];
  if (samples.isEmpty || masks.isEmpty) {
    return DeadReckoningEvaluation(scores);
  }

  for (final mask in masks) {
    final estimator = freshEstimatorForEval(tune, terrain);
    DeadReckoningPosition? predicted;
    DeadReckoningSample? actual;

    for (final sample in samples) {
      if (sample.receivedAtMs < mask.startMs) {
        estimator.update(sample);
        continue;
      }
      if (sample.receivedAtMs < mask.endMs) {
        // Inside the window: hide the fix, keep velocity + timing.
        estimator.extrapolate(sample.receivedAtMs);
        estimator.update(hideFixForEval(sample));
        continue;
      }
      // At/past the window end: the first real fix scores the gap. Project
      // to the fix time first (as the live ticker would), then compare
      // before the fix itself is folded in.
      if (sample.hasFix) {
        estimator.extrapolate(sample.receivedAtMs);
        predicted = estimator.position;
        actual = sample;
        break;
      }
      estimator.extrapolate(sample.receivedAtMs);
      estimator.update(hideFixForEval(sample));
    }

    scores.add(DeadReckoningGapScore(
      mask: mask,
      predicted: predicted,
      actual: actual,
    ));
  }
  return DeadReckoningEvaluation(scores);
}
