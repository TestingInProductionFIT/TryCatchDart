/// Ground-side dead reckoning estimator.
library;

import 'dart:math' as math;

import './geo.dart';
import './position.dart';
import './sample.dart';
import './terrain.dart';
import './tune.dart';

/// Ground-side dead reckoning estimator.
///
/// Pure computation, fully decoupled from serial handling and UI: it is fed
/// [DeadReckoningSample]s (mapped from telemetry frames by a thin app-side
/// adapter) and integrates the rocket's NED velocity to estimate the
/// position between (and extrapolated from) GPS fixes.
///
/// Semantics: the dead reckoning position equals the most recent GPS fix
/// plus the velocity integral since that fix. Between fixes it drifts away
/// from the true position as sensor error accumulates; each new fix
/// re-anchors it.
///
/// ### Gravity correction
/// While samples still arrive ([update]), the avionics' IMU-integrated
/// velocity already accounts for gravity — no correction is applied there.
/// Once the link is lost entirely and [extrapolate] drives the position,
/// an ascending rocket arcs over under gravity (`Δh = v·dt − ½g·dt²`, exact
/// kinematics, correct even for large `dt` gaps) instead of flying to the
/// stratosphere indefinitely. The gravity constant comes from [tune].
///
/// ### Terminal descent
/// A rocket under an open parachute does NOT accelerate downward — it falls
/// at a near-constant terminal rate, so the gravity arc above would plunge
/// the estimate through the ground (measured −80 m vertical error on 10 s
/// parachute outages of the reference flight). The estimator therefore
/// learns the terminal rate from steady pre-outage descent and, once
/// learned, holds/relaxes toward it while descending instead of applying
/// gravity. Ascent always uses the gravity arc; a predicted apogee crossing
/// (vertical velocity passing through zero mid-outage) settles onto the
/// learned terminal rate, which models a chute opening without ever reading
/// in-outage truth — only pre-outage samples and predicted motion are used,
/// so a state change mid-outage is predicted, never leaked.
///
/// ### Terrain floor
/// [setTerrainFloor] accepts an MSL elevation from an external tile query.
/// It is merged with the GPS-minimum heuristic via `max()`, so a stale or
/// imprecise terrain value can only *raise* the clamp — never lower it
/// below a confirmed GPS fix altitude.
///
/// ### Touchdown freeze
/// Once the estimate sinks to the ground floor it is pinned there with
/// zeroed velocity — a landed rocket doesn't keep sliding. A fresh fix
/// clearly above the floor unfreezes it.
///
/// ### Clock monotonicity
/// Sample clocks never move backwards: a sample older than the internal
/// clock still contributes its velocity and GPS anchor, but the clock is
/// held at its high-water mark so one out-of-order sample cannot rewind
/// the integral or inflate the next step.
class DeadReckoningEstimator {
  /// Tuning applied to this estimator. Replace at any time; takes effect on
  /// subsequent samples (already-integrated offsets are kept as-is).
  DeadReckoningTune tune;

  /// Radius (m) inside which a terrain sample refines the ground floor.
  /// Covers a tile and its neighbours at the z=12 tile size the app
  /// queries (≈6 km at 50° lat).
  static const double terrainSampleRadiusM = 15000;

  DeadReckoningEstimator({this.tune = const DeadReckoningTune()});

  // Anchor: the most recent GPS fix.
  double? _anchorLat;
  double? _anchorLon;
  double? _anchorAlt;
  int _anchorAtMs = 0;

  // Velocity integral since the anchor (metres, NED + up).
  double _offN = 0;
  double _offE = 0;
  double _offUp = 0;

  // Last known NED velocity (m/s) from the IMU — used for horizontal
  // extrapolation without fresh samples.
  double _lastVelN = 0;
  double _lastVelE = 0;

  // Previous sample's scaled velocity for trapezoidal live integration.
  double _prevVelN = 0;
  double _prevVelE = 0;
  double _prevVelUp = 0;
  bool _hasPrevVel = false;

  /// Recent raw horizontal velocity samples (ms, m/s) for the
  /// acceleration-trend fit. Time-based (not count-based) so 10 Hz and
  /// 25 Hz links fit the same motion history.
  final List<({int atMs, double velN, double velE})> _velHistory = [];

  /// Remaining seconds the acceleration trend may drive extrapolation.
  /// Refreshed on every live sample; stale acceleration is worse than none.
  double _accelBudgetS = 0;

  /// Fit window (ms of history kept), minimum span (ms), clamp (m/s²) and
  /// trust horizon (s) for the acceleration trend.
  static const int _accelWindowMs = 800;
  static const int _accelMaxPoints = 24;
  static const int _accelMinSpanMs = 400;
  static const double _accelClamp = 25;
  static const double _accelHorizonS = 4;

  /// Vertical velocity (m/s, **upward positive**) used during link-loss
  /// extrapolation. Kept in sync with `-sample.velocityDown` while the link
  /// is live; under gravity it decelerates from there, under a canopy it
  /// holds the learned terminal rate (see [_hasTerminal]).
  double _deadReckoningVelUp = 0;

  /// Whether a terminal descent rate has been learned from steady
  /// pre-outage descent (fix-based, see [_learnVerticalScale]). While set,
  /// descending extrapolation holds toward [_terminalRateDown] instead of
  /// accelerating under gravity. Only ever set from pre-outage GPS fixes —
  /// never from in-outage data.
  bool _descentLearned = false;

  /// Learned terminal descent rate (m/s, positive down): low-pass of the
  /// GPS-altitude descent rate observed while steadily descending.
  double _terminalRateDown = 0;

  /// Minimum fix-to-fix span (s) for one vertical-scale learning update.
  /// Altitude differences over shorter spans are noise-dominated at 25 Hz.
  static const double _learnMinSpanS = 1.5;

  /// Learning updates are skipped unless both the altitude rate and the
  /// reported vertical speed exceed this magnitude (m/s) — near hover the
  /// ratio is meaningless — and the reported speed stayed within
  /// [_learnMaxSpread] over the span (opening shock and sensor ringing
  /// are rejected, never learned from).
  static const double _learnMinRate = 2;

  /// Maximum reported-speed spread (m/s) over one learning span. Canopy
  /// shock and the ringing after it swing tens of m/s per second; steady
  /// flight stays within a couple.
  static const double _learnMaxSpread = 8;

  /// Ascent faster than this (m/s up, raw reported) on a fresh fix clears
  /// the learned descent regime — e.g. a new flight without a reset.
  static const double _reascendClearUp = 5;

  /// Per-step accumulators for vertical-scale learning: raw reported
  /// vertical velocity (up positive) integrated since the previous fix,
  /// plus its min/max so violent spans (opening shock, ringing) can be
  /// rejected instead of learned from.
  double _learnVelSum = 0;
  double _learnDtSum = 0;
  double _learnVelMin = double.infinity;
  double _learnVelMax = double.negativeInfinity;

  /// Previous fix used as the learning baseline (ms, MSL altitude).
  int? _prevFixMs;
  double? _prevFixAlt;

  /// Online vertical scale for climbing samples (reported → true, up
  /// positive). Learned from fix-to-fix altitude rates; starts at 1.
  double _climbScale = 1;

  /// Online vertical scale for descending samples. Starts at 1.
  double _descentScale = 1;

  int? _lastUpdateMs;

  /// Lowest GPS fix altitude seen (MSL) — the touch-down floor heuristic.
  double? _lowestFixMsl;

  /// `true` once the estimate has been pinned to the ground.
  bool _grounded = false;

  /// Terrain elevation (MSL) from an external query — overrides the GPS-min
  /// heuristic when available. Always merged via `max()` with the heuristic
  /// so it can only raise the clamp, never lower it below a confirmed fix.
  double? _terrainFloorMsl;

  /// Terrain shape: known elevations along the flight. The floor is looked
  /// up at the current predicted position (nearest sample inside
  /// [terrainSampleRadiusM]) so a drift over a ridge clamps to the ridge,
  /// not to the valley the rocket launched from.
  final List<DeadReckoningTerrainSample> _terrainSamples = [];

  // ── Public getters ─────────────────────────────────────────────────────────

  /// Ground floor (MSL): the higher of the terrain query and the GPS-min
  /// heuristic, or `null` before the first fix.
  ///
  /// Taking `max()` means a terrain value that is lower than the launch-site
  /// MSL (e.g. the tile covers a nearby valley) is safely overridden by the
  /// confirmed GPS data.
  double? get groundFloorMsl {
    final heuristic = _lowestFixMsl == null
        ? null
        : _lowestFixMsl! - tune.groundToleranceM;
    final terrain = _terrainFloorMsl;
    if (terrain == null) return heuristic;
    if (heuristic == null) return terrain;
    return math.max(terrain, heuristic);
  }

  /// Most recent computed dead reckoning position, if anchored.
  DeadReckoningPosition? get position =>
      _buildPosition(_lastUpdateMs ?? 0);

  DeadReckoningPosition? _buildPosition(int atMs) {
    final lat = _anchorLat;
    if (lat == null) return null;

    final p = offsetLatLon(
      lat,
      _anchorLon!,
      northM: _offN,
      eastM: _offE,
    );
    return DeadReckoningPosition(
      latitude: p.latitude,
      longitude: p.longitude,
      altitude: _anchorAlt! + _offUp,
      atMs: atMs,
      regime: _currentRegime(),
    );
  }

  /// Predicted flight regime for [position]'s `regime` label, derived from
  /// predicted motion only (never in-outage truth).
  String _currentRegime() {
    if (_grounded) return 'landed';
    if (_deadReckoningVelUp > 1) return 'climb';
    if (_deadReckoningVelUp < -1) return 'descent';
    return 'level';
  }

  /// Scales a raw reported vertical velocity (up positive) into the
  /// estimator's best estimate of true velocity, using the online-learned
  /// regime scale selected by the sample's own direction.
  double _scaleVertical(double velUp) =>
      velUp * (velUp >= 0 ? _climbScale : _descentScale);

  /// Time of the anchor fix (Unix epoch ms), or `null` when un-anchored.
  /// Alias of [lastFixAtMs]: the anchor is always the most recent fix.
  int? get anchorTimeMs => lastFixAtMs;

  /// Time of the most recent GPS fix seen (Unix epoch ms), even if a later
  /// sample had no fix — used to detect stale GPS.
  int? get lastFixAtMs => _anchorLat == null ? null : _anchorAtMs;

  /// Horizontal distance travelled since the anchor fix, in metres.
  double get distanceSinceAnchor => math.sqrt(_offN * _offN + _offE * _offE);

  /// Whether the ground floor is backed by a real terrain elevation query
  /// rather than just the GPS-minimum heuristic.
  bool get hasRealTerrainFloor => _terrainFloorMsl != null;

  /// Whether the estimate has passed the tune's extrapolation horizon.
  /// When true the position is held (not projected further) until a fresh
  /// fix arrives. Always false when the tune sets no horizon.
  bool get isExpired {
    final horizon = tune.maxExtrapolationSeconds;
    final clock = _lastUpdateMs;
    if (_anchorLat == null || horizon == null || clock == null) return false;
    return (clock - _anchorAtMs) / 1000.0 > horizon;
  }

  // ── Mutation ───────────────────────────────────────────────────────────────

  /// Sets the ground-collision floor from a terrain elevation query (MSL).
  ///
  /// Merged with the GPS-min heuristic via `max()`, so it only raises the
  /// clamp. Safe to call from an async context after a tile fetch resolves.
  void setTerrainFloor(double msl) {
    _terrainFloorMsl = msl;
  }

  /// Replaces the terrain shape samples (see [_terrainSamples]).
  void setTerrainSamples(List<DeadReckoningTerrainSample> samples) {
    _terrainSamples
      ..clear()
      ..addAll(samples);
  }

  /// Scales + clamps one sample's velocity: horizontal by the tune's
  /// per-rocket IMU scale then the speed clamp, vertical through the
  /// online-learned regime scale then its clamp. Returns (north, east, up).
  (double, double, double) _scaledClampedVelocity(
    DeadReckoningSample sample,
  ) {
    var velN = sample.velocityNorth * tune.velocityScale;
    var velE = sample.velocityEast * tune.velocityScale;
    var velUp = _scaleVertical(-sample.velocityDown);

    final maxHoriz = tune.maxHorizontalSpeed;
    if (maxHoriz != null) {
      final speed = math.sqrt(velN * velN + velE * velE);
      if (speed > maxHoriz && speed > 0) {
        final scale = maxHoriz / speed;
        velN *= scale;
        velE *= scale;
      }
    }
    final maxVert = tune.maxVerticalSpeed;
    if (maxVert != null && velUp.abs() > maxVert) {
      velUp = maxVert * velUp.sign;
    }
    return (velN, velE, velUp);
  }

  /// Applies clamped low-pass velocity adoption for one sample.
  void _adoptVelocity(DeadReckoningSample sample) {
    final (velN, velE, velUp) = _scaledClampedVelocity(sample);

    final alpha = tune.velocityFilterAlpha;
    _lastVelN = alpha * velN + (1 - alpha) * _lastVelN;
    _lastVelE = alpha * velE + (1 - alpha) * _lastVelE;
    // Keep the dead reckoning vertical velocity in sync with the IMU so
    // that if the link dies, extrapolation starts from the correct
    // velocity. Regime learning itself happens fix-to-fix in [_anchorFix];
    // this path only folds the (scaled) sample in.
    _deadReckoningVelUp =
        alpha * velUp + (1 - alpha) * _deadReckoningVelUp;
  }

  void _anchorFix(DeadReckoningSample sample) {
    _anchorLat = sample.latitude;
    _anchorLon = sample.longitude;
    _anchorAlt = sample.gpsAltitude;
    _anchorAtMs = sample.receivedAtMs;
    _offN = 0;
    _offE = 0;
    _offUp = 0;
    // Trapezoidal integration resumes from the anchor's own velocity
    // (scaled but unclamped — clamps apply to adoption/extrapolation).
    _prevVelN = sample.velocityNorth * tune.velocityScale;
    _prevVelE = sample.velocityEast * tune.velocityScale;
    _prevVelUp = _scaleVertical(-sample.velocityDown);
    _hasPrevVel = true;
    _lowestFixMsl = _lowestFixMsl == null
        ? sample.gpsAltitude
        : math.min(_lowestFixMsl!, sample.gpsAltitude);
    // Airborne again (e.g. new flight without a reset) lifts the freeze.
    final floor = groundFloorMsl;
    if (floor == null ||
        sample.gpsAltitude > floor + tune.groundToleranceM) {
      _grounded = false;
    }
    _learnVerticalScale(sample);
  }

  /// Online vertical calibration from fix-to-fix GPS altitude rates.
  ///
  /// Compares the altitude rate between this fix and the previous one
  /// against the mean reported vertical velocity over the same span and
  /// nudges the matching regime scale ([_climbScale]/[_descentScale]) toward
  /// their ratio. Descending updates additionally teach [_terminalRateDown]
  /// and set [_descentLearned] (canopy evidence for terminal-hold
  /// extrapolation). A strongly ascending fix clears the learned descent
  /// regime (new flight). Runs only on fixes with a sufficient baseline —
  /// never on masked/in-outage samples, so no truth leaks into an outage.
  void _learnVerticalScale(DeadReckoningSample sample) {
    final t = sample.receivedAtMs;
    if (sample.velocityDown < -_reascendClearUp) {
      _descentLearned = false;
    }
    // First fix only establishes the baseline; velocity since then keeps
    // accumulating in [update] until the span below is reached.
    if (_prevFixMs == null || _prevFixAlt == null) {
      _prevFixMs = t;
      _prevFixAlt = sample.gpsAltitude;
      _resetLearnSpan();
      return;
    }
    final spanS = (t - _prevFixMs!) / 1000.0;
    if (spanS < _learnMinSpanS || _learnDtSum <= 0.5) return;
    final altRate = (sample.gpsAltitude - _prevFixAlt!) / spanS;
    final meanVel = _learnVelSum / _learnDtSum;
    if (altRate.abs() > _learnMinRate &&
        meanVel.abs() > _learnMinRate &&
        altRate.sign == meanVel.sign &&
        _learnVelMax - _learnVelMin <= _learnMaxSpread) {
      final instant = (altRate / meanVel).clamp(0.2, 2.5);
      if (altRate > 0) {
        _climbScale += (instant - _climbScale) * 0.2;
      } else {
        _descentScale += (instant - _descentScale) * 0.2;
        _terminalRateDown = _terminalRateDown == 0
            ? -altRate
            : 0.8 * _terminalRateDown + 0.2 * -altRate;
        _descentLearned = true;
      }
    }
    // Consumed: the current fix becomes the next baseline.
    _prevFixMs = t;
    _prevFixAlt = sample.gpsAltitude;
    _resetLearnSpan();
  }

  void _resetLearnSpan() {
    _learnVelSum = 0;
    _learnDtSum = 0;
    _learnVelMin = double.infinity;
    _learnVelMax = double.negativeInfinity;
  }

  /// Feeds a telemetry sample and returns the updated dead reckoning
  /// position (`null` before the first GPS fix).
  DeadReckoningPosition? update(DeadReckoningSample sample) {
    final t = sample.receivedAtMs;
    final previous = _lastUpdateMs;

    // Out-of-order sample: fold its velocity and anchor in, but never rewind
    // the clock (which would inflate the next integration step).
    if (previous != null && t < previous) {
      if (!_grounded) _adoptVelocity(sample);
      _prevVelN = sample.velocityNorth * tune.velocityScale;
      _prevVelE = sample.velocityEast * tune.velocityScale;
      _prevVelUp = _scaleVertical(-sample.velocityDown);
      _hasPrevVel = true;
      if (sample.hasFix) _anchorFix(sample);
      _enforceGround();
      return _buildPosition(previous);
    }

    // Frozen on the ground: only the clock advances, no integration and no
    // velocity adoption — the landing spot stays put.
    if (!_grounded) {
      // Trapezoidal rule over instantaneous samples: exact for ramps
      // (what continuous velocity looks like), where backward Euler
      // overshoots every acceleration phase. Vertical endpoints pass
      // through the online-learned regime scale.
      final vN = sample.velocityNorth * tune.velocityScale;
      final vE = sample.velocityEast * tune.velocityScale;
      final vUp = _scaleVertical(-sample.velocityDown);
      if (_hasPrevVel && previous != null && t > previous) {
        final dt = (t - previous) / 1000.0;
        _offN += 0.5 * (_prevVelN + vN) * dt;
        _offE += 0.5 * (_prevVelE + vE) * dt;
        _offUp += 0.5 * (_prevVelUp + vUp) * dt;
        // Raw reported vertical velocity × time for fix-to-fix learning.
        final rawUp = -sample.velocityDown;
        _learnVelSum += rawUp * dt;
        _learnDtSum += dt;
        if (rawUp < _learnVelMin) _learnVelMin = rawUp;
        if (rawUp > _learnVelMax) _learnVelMax = rawUp;
      }
      _prevVelN = vN;
      _prevVelE = vE;
      _prevVelUp = vUp;
      _hasPrevVel = true;
      _adoptVelocity(sample);
      if (tune.accelerationTracking) {
        // Fresh motion data: feed the trend fit and refresh its budget.
        // Skipped entirely when tracking is off (hot path). Pruning is
        // amortized: the memmove runs only past the cap, not per sample.
        _velHistory.add((
          atMs: t,
          velN: vN,
          velE: vE,
        ));
        if (_velHistory.length > _accelMaxPoints) {
          final cutoff = t - _accelWindowMs;
          var drop = 0;
          while (drop < _velHistory.length &&
              _velHistory[drop].atMs < cutoff) {
            drop++;
          }
          drop = math.max(drop, _velHistory.length - _accelMaxPoints);
          _velHistory.removeRange(0, drop);
        }
        _accelBudgetS = _accelHorizonS;
      }
    }
    _lastUpdateMs = t;

    if (sample.hasFix) _anchorFix(sample);

    _enforceGround();
    return _buildPosition(t);
  }

  /// Least-squares acceleration (m/s²) over the recent velocity history,
  /// or `null` when too few/sporadic points exist. Clamped — a spike fit
  /// must never slingshot the projection. Only the freshest window
  /// ([_accelWindowMs]) is fitted, regardless of link rate.
  (double, double)? _fitAccel() {
    if (_velHistory.length < 3) return null;
    final newest = _velHistory.last.atMs;
    final cutoff = newest - _accelWindowMs;
    var start = _velHistory.length - 1;
    while (start > 0 && _velHistory[start - 1].atMs >= cutoff) {
      start--;
    }
    final count = _velHistory.length - start;
    if (count < 3) return null;
    if (newest - _velHistory[start].atMs < _accelMinSpanMs) return null;
    final n = count.toDouble();
    var sumT = 0.0;
    var sumTT = 0.0;
    var sumN = 0.0;
    var sumTN = 0.0;
    var sumE = 0.0;
    var sumTE = 0.0;
    for (var i = start; i < _velHistory.length; i++) {
      final point = _velHistory[i];
      final t = point.atMs / 1000.0;
      sumT += t;
      sumTT += t * t;
      sumN += point.velN;
      sumTN += t * point.velN;
      sumE += point.velE;
      sumTE += t * point.velE;
    }
    final denom = sumTT - sumT * sumT / n;
    if (denom <= 0) return null;
    final aN =
        ((sumTN - sumT * sumN / n) / denom).clamp(-_accelClamp, _accelClamp);
    final aE =
        ((sumTE - sumT * sumE / n) / denom).clamp(-_accelClamp, _accelClamp);
    return (aN.toDouble(), aE.toDouble());
  }

  /// Integrates the last known velocity forward to [atMs] without a fresh
  /// sample — ground-side extrapolation while the link is silent. Advances
  /// the internal clock so a later [update] resumes from here. Frozen once
  /// grounded (only the clock advances).
  ///
  /// **Vertical regimes** (predicted motion only, never in-outage truth):
  /// ascending (or no canopy ever learned) uses the exact-kinematics
  /// gravity arc `Δh = v₀·dt − ½g·dt²`, so the rocket decelerates, peaks,
  /// and descends naturally regardless of how long the extrapolation
  /// window is. Descending with a learned terminal rate holds toward that
  /// rate instead — a canopy falls at constant speed, and gravity would
  /// plunge the estimate through the ground. A predicted apogee crossing
  /// therefore settles onto the learned rate, modelling a chute opening
  /// mid-outage; without any learned rate the fall stays ballistic, which
  /// is correct for powered/coast flight.
  ///
  /// **Acceleration trend** ([DeadReckoningTune.accelerationTracking],
  /// horizontal only): the recent velocity slope bends the projection
  /// (`Δ = v₀·dt + ½a·dt²`, exact), trusted for the first seconds of each
  /// outage. Without it — or past its budget, or with
  /// [DeadReckoningTune.horizontalDrag] set — horizontal velocity is held
  /// constant (conservatively assumes no drag and gives the widest
  /// plausible search area).
  ///
  /// Past [DeadReckoningTune.maxExtrapolationSeconds] the position is held
  /// and [isExpired] reports true until a fresh fix arrives.
  DeadReckoningPosition? extrapolate(int atMs) {
    final horizon = tune.maxExtrapolationSeconds;
    final pastHorizon = horizon != null &&
        _anchorLat != null &&
        (atMs - _anchorAtMs) / 1000.0 > horizon;
    if (!pastHorizon &&
        !_grounded &&
        _lastUpdateMs != null &&
        atMs > _lastUpdateMs!) {
      final dt = (atMs - _lastUpdateMs!) / 1000.0;
      if (tune.horizontalDrag <= 0) {
        _offN += _lastVelN * dt;
        _offE += _lastVelE * dt;
        final accel =
            tune.accelerationTracking && _accelBudgetS > 0 ? _fitAccel() : null;
        if (accel != null) {
          final useDt = math.min(dt, _accelBudgetS);
          _offN += 0.5 * accel.$1 * useDt * useDt;
          _offE += 0.5 * accel.$2 * useDt * useDt;
          _lastVelN += accel.$1 * useDt;
          _lastVelE += accel.$2 * useDt;
        }
        _accelBudgetS = math.max(0, _accelBudgetS - dt);
      } else {
        // Exact integral of exponentially decaying velocity over dt.
        final decay = math.exp(-tune.horizontalDrag * dt);
        final scale = (1 - decay) / tune.horizontalDrag;
        _offN += _lastVelN * scale;
        _offE += _lastVelE * scale;
        _lastVelN *= decay;
        _lastVelE *= decay;
      }
      // Vertical: terminal descent holds toward the learned rate (canopy
      // physics); everything else arcs under gravity (ballistic physics).
      // Exact per-step integration in both branches so 1 s ticks and one
      // large step agree to floating-point rounding over the airborne part.
      if (_descentLearned && _deadReckoningVelUp < -1) {
        final targetUp = -_terminalRateDown;
        final blend = (dt * 0.5).clamp(0.0, 1.0);
        final startVel = _deadReckoningVelUp;
        final endVel = startVel + (targetUp - startVel) * blend;
        _offUp += 0.5 * (startVel + endVel) * dt;
        _deadReckoningVelUp = endVel;
      } else {
        final gravity = tune.gravity;
        _offUp += _deadReckoningVelUp * dt - 0.5 * gravity * dt * dt;
        _deadReckoningVelUp -= gravity * dt;
      }
    }
    if (_lastUpdateMs == null || atMs > _lastUpdateMs!) {
      _lastUpdateMs = atMs;
    }
    _enforceGround();
    return position;
  }

  /// Floor (MSL) at a predicted position: the global floor refined by the
  /// nearest terrain sample inside [terrainSampleRadiusM], via `max()`.
  double? _floorAt(double latitude, double longitude) {
    var floor = groundFloorMsl;
    var nearest = double.infinity;
    double? elevation;
    for (final sample in _terrainSamples) {
      final distance = haversineDistanceM(
        latitude,
        longitude,
        sample.latitude,
        sample.longitude,
      );
      if (distance < terrainSampleRadiusM && distance < nearest) {
        nearest = distance;
        elevation = sample.elevationMsl;
      }
    }
    if (elevation != null) {
      floor = floor == null ? elevation : math.max(floor, elevation);
    }
    return floor;
  }

  /// Pins the estimate to the touchdown floor, freezing all velocity.
  void _enforceGround() {
    final anchorLat = _anchorLat;
    final anchorLon = _anchorLon;
    final anchorAlt = _anchorAlt;
    if (anchorLat == null || anchorLon == null || anchorAlt == null) return;
    final predicted = offsetLatLon(
      anchorLat,
      anchorLon,
      northM: _offN,
      eastM: _offE,
    );
    final floor = _floorAt(predicted.latitude, predicted.longitude);
    if (floor == null) return;
    if (anchorAlt + _offUp < floor) {
      _offUp = floor - anchorAlt;
      _lastVelN = 0;
      _lastVelE = 0;
      _deadReckoningVelUp = 0;
      _velHistory.clear();
      _accelBudgetS = 0;
      _grounded = true;
    }
  }

  /// Clears all state (e.g. on session change). The [tune] is kept.
  void reset() {
    _anchorLat = null;
    _anchorLon = null;
    _anchorAlt = null;
    _anchorAtMs = 0;
    _offN = 0;
    _offE = 0;
    _offUp = 0;
    _lastVelN = 0;
    _lastVelE = 0;
    _deadReckoningVelUp = 0;
    _prevVelN = 0;
    _prevVelE = 0;
    _prevVelUp = 0;
    _hasPrevVel = false;
    _velHistory.clear();
    _accelBudgetS = 0;
    _lastUpdateMs = null;
    _lowestFixMsl = null;
    _terrainFloorMsl = null;
    _terrainSamples.clear();
    _grounded = false;
    _descentLearned = false;
    _terminalRateDown = 0;
    _resetLearnSpan();
    _prevFixMs = null;
    _prevFixAlt = null;
    _climbScale = 1;
    _descentScale = 1;
  }
}
