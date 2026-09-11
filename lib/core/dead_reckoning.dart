import 'dart:math' as math;

import 'package:serial/serial.dart';

import './geo.dart';

/// Dead-reckoned position (WGS84 + MSL altitude).
class DrPosition {
  final double latitude;
  final double longitude;
  final double altitude;

  /// Estimate time (Unix epoch ms) — the frame time or, for extrapolated
  /// points, the wall-clock time the estimate was projected to.
  final int atMs;

  const DrPosition({
    required this.latitude,
    required this.longitude,
    required this.altitude,
    required this.atMs,
  });

  @override
  String toString() =>
      'DrPosition(${latitude.toStringAsFixed(6)}, ${longitude.toStringAsFixed(6)}, ${altitude.toStringAsFixed(1)}m)';
}

/// Ground-side dead-reckoning estimator.
///
/// Pure computation, fully decoupled from serial handling and UI: it is fed
/// [TelemetryFrame]s and integrates the rocket's NED velocity to estimate the
/// position between (and extrapolated from) GPS fixes.
///
/// Semantics: the DR position equals the most recent GPS fix plus the
/// velocity integral since that fix. Between fixes it drifts away from the
/// true position as sensor error accumulates; each new fix re-anchors it.
///
/// ### Gravity correction
/// While telemetry frames still arrive ([update]), the avionics' IMU-integrated
/// velocity already accounts for gravity — no correction is applied there.
/// Once the link is lost entirely and [extrapolate] drives the position,
/// `g = 9.81 m/s²` decelerates the vertical velocity so an ascending rocket
/// arcs over and descends instead of flying to the stratosphere indefinitely.
/// The exact-kinematics formula `Δh = v·dt − ½g·dt²` is used rather than
/// Euler integration, so the result is correct even for large `dt` gaps.
///
/// ### Terrain floor
/// [setTerrainFloor] accepts an MSL elevation from an external tile query
/// (see `elevation_service.dart`). It is merged with the GPS-minimum
/// heuristic via `max()`, so a stale or imprecise terrain value can only
/// *raise* the clamp — never lower it below a confirmed GPS fix altitude.
///
/// ### Touchdown freeze
/// Once the estimate sinks to the ground floor it is pinned there with zeroed
/// velocity — a landed rocket doesn't keep sliding. A fresh fix clearly above
/// the floor unfreezes it.
class DeadReckoningEstimator {
  /// Touchdown tolerance below the lowest seen fix (GPS noise margin).
  static const double groundToleranceM = 2.0;

  /// Standard gravity (m/s²).
  static const double _gravity = 9.80665;

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
  // extrapolation without fresh frames.
  double _lastVelN = 0;
  double _lastVelE = 0;

  /// Vertical velocity (m/s, **upward positive**) used during link-loss
  /// extrapolation.  Kept in sync with `-frame.velocityDown` while the link
  /// is live; decays under gravity once [extrapolate] takes over, so the
  /// rocket arcs over instead of flying straight.
  double _drVelUp = 0;

  int? _lastUpdateMs;

  /// Lowest GPS fix altitude seen (MSL) — the touch-down floor heuristic.
  double? _lowestFixMsl;

  /// `true` once the estimate has been pinned to the ground.
  bool _grounded = false;

  /// Terrain elevation (MSL) from an external query — overrides the GPS-min
  /// heuristic when available.  Always merged via `max()` with the heuristic
  /// so it can only raise the clamp, never lower it below a confirmed fix.
  double? _terrainFloorMsl;

  // ── Public getters ─────────────────────────────────────────────────────────

  /// Ground floor (MSL): the higher of the terrain query and the GPS-min
  /// heuristic, or `null` before the first fix.
  ///
  /// Taking `max()` means a terrain value that is lower than the launch-site
  /// MSL (e.g. the tile covers a nearby valley) is safely overridden by the
  /// confirmed GPS data.
  double? get groundFloorMsl {
    final heuristic =
        _lowestFixMsl == null ? null : _lowestFixMsl! - groundToleranceM;
    final terrain = _terrainFloorMsl;
    if (terrain == null) return heuristic;
    if (heuristic == null) return terrain;
    return math.max(terrain, heuristic);
  }

  /// Most recent computed DR position, if the estimator has been anchored.
  DrPosition? get position => _buildPosition(_lastUpdateMs ?? 0);

  DrPosition? _buildPosition(int atMs) {
    final lat = _anchorLat;
    if (lat == null) return null;

    final p = offsetLatLon(
      lat,
      _anchorLon!,
      northM: _offN,
      eastM: _offE,
    );
    return DrPosition(
      latitude: p.latitude,
      longitude: p.longitude,
      altitude: _anchorAlt! + _offUp,
      atMs: atMs,
    );
  }

  /// Time of the anchor fix (Unix epoch ms), or `null` when un-anchored.
  int? get anchorTimeMs => _anchorLat == null ? null : _anchorAtMs;

  /// Time of the most recent GPS fix seen (Unix epoch ms), even if a later
  /// frame had no fix — used to detect stale GPS.
  int? get lastFixAtMs => _anchorLat == null ? null : _anchorAtMs;

  /// Horizontal distance travelled since the anchor fix, in metres.
  double get distanceSinceAnchor => math.sqrt(_offN * _offN + _offE * _offE);

  /// Whether the ground floor is backed by a real terrain elevation query
  /// rather than just the GPS-minimum heuristic.
  bool get hasRealTerrainFloor => _terrainFloorMsl != null;

  // ── Mutation ───────────────────────────────────────────────────────────────

  /// Sets the ground-collision floor from a terrain elevation query (MSL).
  ///
  /// Merged with the GPS-min heuristic via `max()`, so it only raises the
  /// clamp.  Safe to call from an async context after a tile fetch resolves.
  void setTerrainFloor(double msl) {
    _terrainFloorMsl = msl;
  }

  /// Feeds a telemetry frame and returns the updated DR position
  /// (`null` before the first GPS fix).
  DrPosition? update(TelemetryFrame frame) {
    final t = frame.receivedAtMs;

    // Frozen on the ground: only the clock advances, no integration and no
    // velocity adoption — the landing spot stays put.
    if (!_grounded) {
      if (_lastUpdateMs != null && t > _lastUpdateMs!) {
        final dt = (t - _lastUpdateMs!) / 1000.0;
        _offN += frame.velocityNorth * dt;
        _offE += frame.velocityEast * dt;
        _offUp += -frame.velocityDown * dt;
      }
      _lastVelN = frame.velocityNorth;
      _lastVelE = frame.velocityEast;
      // Keep the DR vertical velocity in sync with the IMU so that if the
      // link dies, gravity-corrected extrapolation starts from the correct
      // velocity and decelerates from there.
      _drVelUp = -frame.velocityDown;
    }
    _lastUpdateMs = t;

    if (frame.gpsHasFix) {
      _anchorLat = frame.latitude;
      _anchorLon = frame.longitude;
      _anchorAlt = frame.gpsAltitude;
      _anchorAtMs = t;
      _offN = 0;
      _offE = 0;
      _offUp = 0;
      _lowestFixMsl = _lowestFixMsl == null
          ? frame.gpsAltitude
          : math.min(_lowestFixMsl!, frame.gpsAltitude);
      // Airborne again (e.g. new flight without a reset) lifts the freeze.
      final floor = groundFloorMsl;
      if (floor == null || frame.gpsAltitude > floor + groundToleranceM) {
        _grounded = false;
      }
    }

    _enforceGround();
    return _buildPosition(t);
  }

  /// Integrates the last known velocity forward to [atMs] without a fresh
  /// frame — ground-side extrapolation while the link is silent.  Advances the
  /// internal clock so a later [update] resumes from here.  Frozen once
  /// grounded (only the clock advances).
  ///
  /// **Gravity correction**: the vertical component is integrated with
  /// `Δh = v·dt − ½g·dt²` (exact kinematics for constant gravity), so the
  /// rocket decelerates, peaks, and descends naturally regardless of how long
  /// the extrapolation window is.  Horizontal velocity is held constant
  /// (conservatively assumes no drag — gives the widest plausible search area).
  DrPosition? extrapolate(int atMs) {
    if (!_grounded && _lastUpdateMs != null && atMs > _lastUpdateMs!) {
      final dt = (atMs - _lastUpdateMs!) / 1000.0;
      _offN += _lastVelN * dt;
      _offE += _lastVelE * dt;
      // Exact kinematics: Δh = v₀·dt − ½g·dt².  Update position first, then
      // velocity, so the stored _drVelUp is the end-of-step value ready for
      // the next call.
      _offUp += _drVelUp * dt - 0.5 * _gravity * dt * dt;
      _drVelUp -= _gravity * dt;
    }
    if (_lastUpdateMs == null || atMs > _lastUpdateMs!) {
      _lastUpdateMs = atMs;
    }
    _enforceGround();
    return position;
  }

  /// Pins the estimate to the touchdown floor, freezing all velocity.
  void _enforceGround() {
    final floor = groundFloorMsl;
    final anchorAlt = _anchorAlt;
    if (floor == null || anchorAlt == null) return;
    if (anchorAlt + _offUp < floor) {
      _offUp = floor - anchorAlt;
      _lastVelN = 0;
      _lastVelE = 0;
      _drVelUp = 0;
      _grounded = true;
    }
  }

  /// Clears all state (e.g. on session change).
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
    _drVelUp = 0;
    _lastUpdateMs = null;
    _lowestFixMsl = null;
    _terrainFloorMsl = null;
    _grounded = false;
  }
}
