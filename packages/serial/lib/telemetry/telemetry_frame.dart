/// Decoded telemetry frame model and flight software state definitions.
library;

import 'dart:math' as math;

/// Flight software finite state machine states reported by the rocket.
///
/// Wire values are the `id` of each state; ordering of the enum must not be
/// relied upon when serializing — always use [id].
///
/// Each state carries the physical configuration it implies: whether the
/// nosecone is on and whether the parachute is open. The 3D views render
/// directly from these flags.
enum FsmState {
  /// Sitting on the pad, pre-flight checks, GPS acquiring. Assembled.
  idle(0, 'Idle'),

  /// Armed and waiting for ignition. Assembled.
  armed(1, 'Armed'),

  /// Powered ascent and ballistic coast after burnout. Assembled.
  ascent(2, 'Ascent'),

  /// Apogee reached, nosecone popped, waiting for the parachute to open.
  apogee(3, 'Apogee'),

  /// Descending under the open parachute (nosecone gone).
  parachute(4, 'Parachute'),

  /// Touchdown, flight over. Recovery gear jettisoned/collapsed.
  landed(5, 'Landed'),

  /// Bench debug with the airframe open (no nosecone, no parachute).
  debugUnlocked(6, 'Debug - Unlocked'),

  /// Bench debug in flight configuration (nosecone on, no parachute).
  debugLocked(7, 'Debug - Locked'),

  /// Placeholder used when an unmapped wire value is received.
  unknown(255, 'Unknown');

  const FsmState(this.id, this.label);

  /// Value carried in the telemetry frame's FSM byte (wire v2).
  final int id;

  /// Human-friendly name for UI display.
  final String label;

  /// Whether the nosecone is on in this state.
  bool get hasNosecone => switch (this) {
        FsmState.idle ||
        FsmState.armed ||
        FsmState.ascent ||
        FsmState.debugLocked =>
          true,
        FsmState.apogee ||
        FsmState.parachute ||
        FsmState.landed ||
        FsmState.debugUnlocked ||
        FsmState.unknown =>
          false,
      };

  /// Whether the parachute is open in this state.
  bool get hasParachute => this == FsmState.parachute;

  /// Maps a wire value to a state, falling back to [unknown].
  static FsmState fromId(int id) =>
      FsmState.values.firstWhere((s) => s.id == id, orElse: () => FsmState.unknown);

  /// Maps a v1 wire id onto the v2 state set (v1: 0 idle, 1 armed, 2 boost,
  /// 3 coast, 4 apogee, 5 drogue, 6 main, 7 landed, 8 fault).
  static FsmState fromV1Id(int id) => switch (id) {
        0 => FsmState.idle,
        1 => FsmState.armed,
        2 || 3 => FsmState.ascent,
        4 => FsmState.apogee,
        5 || 6 => FsmState.parachute,
        7 => FsmState.landed,
        _ => FsmState.unknown,
      };
}

/// Bit positions inside the telemetry frame's flags byte.
abstract final class FrameFlags {
  /// GPS has a 2D position fix.
  static const int gpsFix = 1 << 0;

  /// GPS has a 3D (altitude) fix.
  static const int gpsFix3d = 1 << 1;
}

/// A single fully decoded telemetry frame in SI units.
///
/// Produced by decoding a [TelemetryPacket]'s raw payload via [FrameCodec].
///
/// Conventions:
/// - Position: WGS84 degrees; altitudes in metres.
/// - Velocity: NED frame (North, East, Down) in m/s — [velocityDown] is
///   positive towards the ground.
/// - Acceleration: body frame in m/s² (specific force, i.e. +9.81 on the pad).
/// - Gyro: body frame rotation in deg/s.
/// - Attitude ([roll], [pitch], [yaw]) is rocket-oriented rather than
///   aircraft-oriented:
///   - `pitch` — tilt away from vertical (0° = nose straight up, 90° = horizontal)
///   - `yaw`   — compass heading the nose points towards (0–360°)
///   - `roll`  — spin about the longitudinal axis (deg, unbounded)
class TelemetryFrame {
  /// Wall-clock time the frame was parsed (Unix epoch, ms).
  final int receivedAtMs;

  /// Wire format version this frame was decoded from.
  final int version;

  /// Raw flags byte — see [FrameFlags] helpers below.
  final int flags;

  /// Rolling sequence number assigned by the rocket (detects dropped frames).
  final int sequence;

  /// WGS84 latitude in degrees (positive North).
  final double latitude;

  /// WGS84 longitude in degrees (positive East).
  final double longitude;

  /// GPS-reported altitude in metres above mean sea level.
  final double gpsAltitude;

  /// Pressure (barometric) altitude in metres above the launch site.
  final double baroAltitude;

  /// North velocity in m/s.
  final double velocityNorth;

  /// East velocity in m/s.
  final double velocityEast;

  /// Down velocity in m/s (positive towards the ground).
  final double velocityDown;

  /// Body-frame X acceleration in m/s².
  final double accelX;

  /// Body-frame Y acceleration in m/s².
  final double accelY;

  /// Body-frame Z (longitudinal) acceleration in m/s².
  final double accelZ;

  /// Body-frame X rotation rate in deg/s.
  final double gyroX;

  /// Body-frame Y rotation rate in deg/s.
  final double gyroY;

  /// Body-frame Z (longitudinal) rotation rate in deg/s.
  final double gyroZ;

  /// Compass heading in degrees [0, 360).
  final double heading;

  /// Roll about the longitudinal axis in degrees.
  final double roll;

  /// Tilt away from vertical in degrees (0 = straight up).
  final double pitch;

  /// Nose compass heading in degrees.
  final double yaw;

  /// Battery voltage in volts.
  final double batteryVoltage;

  /// Raw hall sensor reading (breakaway wire), dimensionless ADC count,
  /// typically a few thousand.
  final int hallRaw;

  /// Raw FSM state byte as received (use [fsmState] for the enum).
  final int fsmStateId;

  /// Decoded FSM state; [FsmState.unknown] for unmapped values.
  FsmState get fsmState => FsmState.fromId(fsmStateId);

  /// Whether the GPS reported any position fix.
  bool get gpsHasFix => flags & FrameFlags.gpsFix != 0;

  /// Whether the GPS reported a 3D fix.
  bool get gpsHas3dFix => flags & FrameFlags.gpsFix3d != 0;

  /// Total (3D) speed in m/s.
  double get speedTotal =>
      _sqrt(velocityNorth * velocityNorth + velocityEast * velocityEast + velocityDown * velocityDown);

  /// Horizontal (ground) speed in m/s.
  double get speedHorizontal =>
      _sqrt(velocityNorth * velocityNorth + velocityEast * velocityEast);

  /// Vertical speed in m/s, positive up.
  double get speedVertical => -velocityDown;

  /// Total (3D) body acceleration magnitude in m/s².
  double get accelTotal =>
      _sqrt(accelX * accelX + accelY * accelY + accelZ * accelZ);

  /// Horizontal body acceleration magnitude in m/s².
  double get accelHorizontal => _sqrt(accelX * accelX + accelY * accelY);

  const TelemetryFrame({
    this.receivedAtMs = 0,
    this.version = 1,
    this.flags = 0,
    this.sequence = 0,
    this.latitude = 0,
    this.longitude = 0,
    this.gpsAltitude = 0,
    this.baroAltitude = 0,
    this.velocityNorth = 0,
    this.velocityEast = 0,
    this.velocityDown = 0,
    this.accelX = 0,
    this.accelY = 0,
    this.accelZ = 0,
    this.gyroX = 0,
    this.gyroY = 0,
    this.gyroZ = 0,
    this.heading = 0,
    this.roll = 0,
    this.pitch = 0,
    this.yaw = 0,
    this.batteryVoltage = 0,
    this.hallRaw = 0,
    this.fsmStateId = 0,
  });

  static double _sqrt(double v) {
    if (v <= 0) return 0;
    final r = math.sqrt(v);
    return r.isNaN ? 0 : r;
  }
}
