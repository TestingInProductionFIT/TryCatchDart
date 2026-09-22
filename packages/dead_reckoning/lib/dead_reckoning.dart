/// Ground-side dead reckoning estimation for model rocket telemetry.
///
/// Pure Dart (no Flutter, no serial link): the app feeds
/// [DeadReckoningSample]s into [DeadReckoningEstimator] and reads back
/// [DeadReckoningPosition]s. [DeadReckoningTune] carries the portable
/// tuning, [evaluateDeadReckoning] scores a tune against a recording.
library;

export 'src/estimator.dart';
export 'src/eval.dart';
export 'src/geo.dart';
export 'src/optimize.dart';
export 'src/position.dart';
export 'src/sample.dart';
export 'src/terrain.dart';
export 'src/tune.dart';
