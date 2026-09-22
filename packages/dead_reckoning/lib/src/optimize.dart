/// Automatic per-rocket tuning of the dead reckoning estimator.
///
/// [optimizeDeadReckoning] searches the portable tune space with coordinate
/// descent, scoring every candidate with the rotation-invariant mean miss
/// (see `eval.dart`) so the winner has no wind-direction bias. Gravity is
/// deliberately fixed physics and never searched; velocity scale is swept
/// first because per-rocket IMU scale error dominates real flights.
///
/// The search rotates the flight once and reuses the rotated copies for
/// every candidate, and yields to the event loop between candidates so a UI
/// can report progress and cancel.
library;

import 'dart:math' as math;

import './eval.dart';
import './position.dart';
import './sample.dart';
import './terrain.dart';
import './tune.dart';

/// Predicted track through masked windows, oldest first — powers the
/// lab's prediction-vs-truth preview (single heading, the flown one).
class DeadReckoningPrediction {
  /// Window the fixes were hidden in.
  final DeadReckoningGapMask mask;

  /// Estimator position at every masked sample, oldest first.
  final List<DeadReckoningPosition> track;

  const DeadReckoningPrediction({required this.mask, required this.track});
}

/// Replays [samples] with fixes hidden inside each mask, recording the
/// estimator position at every masked sample (not just the window end).
List<DeadReckoningPrediction> predictDeadReckoningTrack({
  required List<DeadReckoningSample> samples,
  required DeadReckoningTune tune,
  required List<DeadReckoningGapMask> masks,
  List<DeadReckoningTerrainSample> terrain = const [],
}) {
  final predictions = <DeadReckoningPrediction>[];
  for (final mask in masks) {
    final estimator = freshEstimatorForEval(tune, terrain);
    final track = <DeadReckoningPosition>[];
    for (final sample in samples) {
      if (sample.receivedAtMs < mask.startMs) {
        estimator.update(sample);
        continue;
      }
      if (sample.receivedAtMs >= mask.endMs) break;
      estimator.extrapolate(sample.receivedAtMs);
      final position = estimator.update(hideFixForEval(sample));
      if (position != null) track.add(position);
    }
    predictions.add(DeadReckoningPrediction(mask: mask, track: track));
  }
  return predictions;
}

/// Progress snapshot delivered to [optimizeDeadReckoning]'s `onProgress`.
class DeadReckoningOptimizationProgress {
  /// Candidates scored so far (including the start tune).
  final int stepsDone;

  /// Upper bound on total candidates (passes × dims + 1).
  final int stepsTotal;

  /// Best tune found so far.
  final DeadReckoningTune bestTune;

  /// Its rotation-invariant mean miss (m).
  final double bestMeanM;

  const DeadReckoningOptimizationProgress({
    required this.stepsDone,
    required this.stepsTotal,
    required this.bestTune,
    required this.bestMeanM,
  });
}

/// Result of [optimizeDeadReckoning].
class DeadReckoningOptimizationResult {
  /// Winning tune (inputs that never helped keep their start values —
  /// ties always keep the incumbent, so a steady flight returns the
  /// start tune untouched).
  final DeadReckoningTune tune;

  /// Final rotation-invariant scoring of [tune].
  final DeadReckoningRotationInvariantEvaluation evaluation;

  /// Candidates scored (including the start tune).
  final int evaluationsRun;

  /// Whether the search ran all passes (`false` when cancelled).
  final bool completed;

  const DeadReckoningOptimizationResult({
    required this.tune,
    required this.evaluation,
    required this.evaluationsRun,
    required this.completed,
  });
}

/// Coordinate-descent sweep grid for [best]: incumbent value first in each
/// dim so ties keep it. Ordered by expected impact.
List<List<DeadReckoningTune>> buildOptimizationSweeps(
  DeadReckoningTune best,
) {
  return <List<DeadReckoningTune>>[
    [
      for (final v in {
        best.velocityScale,
        1.0,
        1.05,
        1.1,
        1.15,
        1.2,
        1.25,
        1.3,
        1.4,
        0.95,
        0.9,
        0.8
      })
        best.copyWith(velocityScale: v)
    ],
    [
      for (final v in {best.horizontalDrag, 0.0, 0.01, 0.02, 0.05, 0.1, 0.2})
        best.copyWith(horizontalDrag: v)
    ],
    [
      for (final v in {best.velocityFilterAlpha, 1.0, 0.85, 0.7, 0.5})
        best.copyWith(velocityFilterAlpha: v)
    ],
    [
      for (final v in {best.groundToleranceM, 2.0, 1.0, 3.0, 5.0, 0.5})
        best.copyWith(groundToleranceM: v)
    ],
    [
      for (final v in {best.maxHorizontalSpeed, 150.0, 80.0, 40.0})
        best.copyWith(maxHorizontalSpeed: v)
    ],
    [
      for (final v in {best.maxVerticalSpeed, 150.0, 80.0})
        best.copyWith(maxVerticalSpeed: v)
    ],
    [
      for (final v in {best.maxExtrapolationSeconds, 300.0, 120.0, 30.0})
        best.copyWith(maxExtrapolationSeconds: v)
    ],
    [best, best.copyWith(accelerationTracking: !best.accelerationTracking)],
  ];
}

/// Upper-bound sweep width used for progress reporting, derived from the
/// grid above so the two cannot drift apart.
int optimizationSearchWidth(DeadReckoningTune tune) => buildOptimizationSweeps(
      tune,
    ).fold(0, (sum, sweep) => sum + sweep.length);

/// Finds the best portable tune for one flight via coordinate descent.
///
/// Searches velocity scale (fine 0.05 steps around 1.0), horizontal drag,
/// velocity smoothing, ground tolerance, the two speed clamps, the
/// extrapolation horizon and the acceleration-trend toggle — never
/// gravity. Each dim is swept while the others are held; the sweep
/// repeats for [maxPasses] passes or until a pass changes nothing.
/// Strict improvement wins, so ties keep the start tune.
///
/// The objective is the duration-weighted rotation-invariant mean miss
/// (see `eval.dart`): short windows weigh more per second of outage so a
/// single 45 s window cannot outvote the short ones.
///
/// Rotates the flight once up front and reuses the copies for every
/// candidate. Awaits a zero-duration future between candidates so callers
/// can paint progress; aborts early when [shouldCancel] returns true.
Future<DeadReckoningOptimizationResult> optimizeDeadReckoning({
  required List<DeadReckoningSample> samples,
  required List<DeadReckoningGapMask> masks,
  int rotationCount = 4,
  DeadReckoningTune start = DeadReckoningTune.defaults,
  List<DeadReckoningTerrainSample> terrain = const [],
  int maxPasses = 2,
  bool Function()? shouldCancel,
  Future<void> Function(DeadReckoningOptimizationProgress)? onProgress,
}) async {
  assert(rotationCount > 0 && maxPasses > 0);
  final rotated = rotatedCopies(samples, rotationCount);

  DeadReckoningRotationInvariantEvaluation score(DeadReckoningTune tune) =>
      evaluateRotatedSampleSets(
          rotated: rotated, tune: tune, masks: masks, terrain: terrain);

  var best = start;
  var bestEval = score(best);
  var bestMean = bestEval.weightedMeanHorizontalErrorM;
  var evaluationsRun = 1;
  // Width is an upper bound (incumbent-first dedup skips one per sweep);
  // capture from the start tune so progress stays monotonic.
  final searchWidth = optimizationSearchWidth(start);

  Future<void> report() async {
    await Future<void>.delayed(Duration.zero);
    final mean = bestMean;
    if (mean == null) return;
    await onProgress?.call(DeadReckoningOptimizationProgress(
      stepsDone: evaluationsRun,
      stepsTotal: searchWidth * maxPasses + 1,
      bestTune: best,
      bestMeanM: mean,
    ));
  }

  // Nothing scored (e.g. every mask predates the first anchor) — there is
  // nothing to optimize; hand the start tune back untouched.
  if (bestMean == null) {
    return DeadReckoningOptimizationResult(
      tune: best,
      evaluation: bestEval,
      evaluationsRun: 0,
      completed: true,
    );
  }
  await report();

  var completed = true;
  for (var pass = 0; pass < maxPasses; pass++) {
    var changed = false;
    for (final sweep in buildOptimizationSweeps(best)) {
      for (final candidate in sweep) {
        if (shouldCancel?.call() ?? false) {
          completed = false;
          return DeadReckoningOptimizationResult(
            tune: best,
            evaluation: bestEval,
            evaluationsRun: evaluationsRun,
            completed: completed,
          );
        }
        // Skip re-scoring the incumbent (first entry of every sweep).
        if (candidate == best) continue;
        final evaluation = score(candidate);
        evaluationsRun++;
        final mean = evaluation.weightedMeanHorizontalErrorM;
        if (mean != null && mean < bestMean! - 1e-9) {
          best = candidate;
          bestEval = evaluation;
          bestMean = mean;
          changed = true;
        }
        await report();
      }
    }
    if (!changed) break;
  }

  return DeadReckoningOptimizationResult(
    tune: best,
    evaluation: bestEval,
    evaluationsRun: evaluationsRun,
    completed: completed,
  );
}

// Re-exported for tests that assert rotation math with π.
double get optimizationPi => math.pi;
