/// Portable dead reckoning tuning.
///
/// A [DeadReckoningTune] is a small plain-data object (~7 numbers) that can
/// be persisted locally, pasted as a short string, or shared as a JSON file
/// between ground stations. Defaults reproduce the historical estimator
/// behaviour (no filtering, no drag, unbounded extrapolation).
library;

import 'dart:convert';

import 'package:meta/meta.dart';

/// Compact string prefix for copy-pasteable tunes.
const String deadReckoningTunePrefix = 'DEADRECKONING1.';

/// Tuning parameters for [DeadReckoningEstimator].
@immutable
class DeadReckoningTune {
  /// Format version for JSON payloads.
  static const int formatVersion = 1;

  /// Gravity used for the vertical arc during link-loss extrapolation
  /// (m/s², positive). Defaults to standard gravity.
  final double gravity;

  /// Horizontal velocity decay during extrapolation (1/s, exponential).
  /// `0` holds velocity constant (widest plausible search area, historical
  /// behaviour); values around `0.01–0.05` model drag over long gaps.
  final double horizontalDrag;

  /// Low-pass factor for adopting fresh velocity samples (`0–1`).
  /// `1` adopts the raw sample (historical behaviour); lower values smooth
  /// single-sample spikes at the cost of lag.
  final double velocityFilterAlpha;

  /// Scale applied to adopted horizontal velocity (dimensionless).
  /// `1` trusts the sensor (historical behaviour); per-rocket IMU scale
  /// error shows up as a consistent under/over-read versus the GPS track
  /// (e.g. 0.75 on the reference flight) and this compensates it.
  final double velocityScale;

  /// Whether link-loss extrapolation follows the recent acceleration trend
  /// (least-squares fit over the last velocity samples, horizontal only).
  /// A steady flight is unaffected (fitted acceleration ≈ 0); a braking
  /// or turning leg bends the projection with it instead of flying
  /// straight. The trend is trusted for the first few seconds of each
  /// outage only — stale acceleration is worse than none.
  final bool accelerationTracking;

  /// Clamp for adopted horizontal speed (m/s), or `null` for no clamp.
  /// Samples above the clamp are scaled down, never dropped.
  final double? maxHorizontalSpeed;

  /// Clamp for adopted vertical speed magnitude (m/s), or `null` for none.
  final double? maxVerticalSpeed;

  /// Touchdown tolerance below the lowest seen fix (GPS noise margin, m).
  final double groundToleranceM;

  /// Maximum extrapolation horizon after the anchor fix (s), or `null` for
  /// unbounded (historical behaviour). Past the horizon the estimator holds
  /// its position and reports [DeadReckoningEstimator.isExpired] instead of
  /// projecting ever further.
  final double? maxExtrapolationSeconds;

  const DeadReckoningTune({
    this.gravity = 9.80665,
    this.horizontalDrag = 0,
    this.velocityFilterAlpha = 1,
    this.velocityScale = 1,
    this.accelerationTracking = true,
    this.maxHorizontalSpeed,
    this.maxVerticalSpeed,
    this.groundToleranceM = 2.0,
    this.maxExtrapolationSeconds,
  })  : assert(gravity >= 0),
        assert(horizontalDrag >= 0),
        assert(velocityFilterAlpha >= 0 && velocityFilterAlpha <= 1),
        assert(velocityScale > 0 && velocityScale <= 3),
        assert(groundToleranceM >= 0);

  /// Factory defaults (historical estimator behaviour).
  static const DeadReckoningTune defaults = DeadReckoningTune();

  DeadReckoningTune copyWith({
    double? gravity,
    double? horizontalDrag,
    double? velocityFilterAlpha,
    double? velocityScale,
    bool? accelerationTracking,
    double? maxHorizontalSpeed,
    double? maxVerticalSpeed,
    double? groundToleranceM,
    double? maxExtrapolationSeconds,
  }) {
    return DeadReckoningTune(
      gravity: gravity ?? this.gravity,
      horizontalDrag: horizontalDrag ?? this.horizontalDrag,
      velocityFilterAlpha: velocityFilterAlpha ?? this.velocityFilterAlpha,
      velocityScale: velocityScale ?? this.velocityScale,
      accelerationTracking: accelerationTracking ?? this.accelerationTracking,
      maxHorizontalSpeed: maxHorizontalSpeed ?? this.maxHorizontalSpeed,
      maxVerticalSpeed: maxVerticalSpeed ?? this.maxVerticalSpeed,
      groundToleranceM: groundToleranceM ?? this.groundToleranceM,
      maxExtrapolationSeconds:
          maxExtrapolationSeconds ?? this.maxExtrapolationSeconds,
    );
  }

  /// JSON representation (includes [formatVersion]).
  Map<String, Object?> toJson() => {
        'version': formatVersion,
        'gravity': gravity,
        'horizontalDrag': horizontalDrag,
        'velocityFilterAlpha': velocityFilterAlpha,
        'velocityScale': velocityScale,
        'accelerationTracking': accelerationTracking,
        if (maxHorizontalSpeed != null)
          'maxHorizontalSpeed': maxHorizontalSpeed,
        if (maxVerticalSpeed != null) 'maxVerticalSpeed': maxVerticalSpeed,
        'groundToleranceM': groundToleranceM,
        if (maxExtrapolationSeconds != null)
          'maxExtrapolationSeconds': maxExtrapolationSeconds,
      };

  /// Parses [toJson] output. Unknown fields are ignored; missing optional
  /// fields default to `null` (no clamp / unbounded).
  factory DeadReckoningTune.fromJson(Map<String, Object?> json) {
    double dbl(Object? v, double fallback) =>
        (v is num) ? v.toDouble() : fallback;
    double? optDbl(Object? v) => (v is num) ? v.toDouble() : null;
    return DeadReckoningTune(
      gravity: dbl(json['gravity'], 9.80665),
      horizontalDrag: dbl(json['horizontalDrag'], 0),
      velocityFilterAlpha: dbl(json['velocityFilterAlpha'], 1)
          .clamp(0.0, 1.0)
          .toDouble(),
      velocityScale: dbl(json['velocityScale'], 1)
          .clamp(0.01, 3.0)
          .toDouble(),
      accelerationTracking: json['accelerationTracking'] is bool
          ? json['accelerationTracking'] as bool
          : true,
      maxHorizontalSpeed: optDbl(json['maxHorizontalSpeed']),
      maxVerticalSpeed: optDbl(json['maxVerticalSpeed']),
      groundToleranceM: dbl(json['groundToleranceM'], 2.0),
      maxExtrapolationSeconds: optDbl(json['maxExtrapolationSeconds']),
    );
  }

  /// Short copy-pasteable string: `<prefix><base64url(json)>`.
  String toCompactString() {
    final raw = utf8.encode(jsonEncode(toJson()));
    return '$deadReckoningTunePrefix${base64Url.encode(raw)}';
  }

  /// Parses [toCompactString] output. Returns `null` on any format error.
  static DeadReckoningTune? parseCompact(String input) {
    final text = input.trim();
    if (!text.startsWith(deadReckoningTunePrefix)) return null;
    try {
      final raw = base64Url.decode(text.substring(deadReckoningTunePrefix.length));
      final decoded = jsonDecode(utf8.decode(raw));
      if (decoded is! Map<String, Object?>) return null;
      return DeadReckoningTune.fromJson(decoded);
    } catch (_) {
      return null;
    }
  }

  @override
  bool operator ==(Object other) =>
      other is DeadReckoningTune &&
      gravity == other.gravity &&
      horizontalDrag == other.horizontalDrag &&
      velocityFilterAlpha == other.velocityFilterAlpha &&
      velocityScale == other.velocityScale &&
      accelerationTracking == other.accelerationTracking &&
      maxHorizontalSpeed == other.maxHorizontalSpeed &&
      maxVerticalSpeed == other.maxVerticalSpeed &&
      groundToleranceM == other.groundToleranceM &&
      maxExtrapolationSeconds == other.maxExtrapolationSeconds;

  @override
  int get hashCode => Object.hash(
        gravity,
        horizontalDrag,
        velocityFilterAlpha,
        velocityScale,
        accelerationTracking,
        maxHorizontalSpeed,
        maxVerticalSpeed,
        groundToleranceM,
        maxExtrapolationSeconds,
      );

  @override
  String toString() => 'DeadReckoningTune(${toCompactString()})';
}
