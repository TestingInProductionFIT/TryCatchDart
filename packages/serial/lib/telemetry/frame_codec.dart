/// Wire-format layout, encoding/decoding and CRC for telemetry frames.
library;

import 'dart:typed_data';

import '../constants.dart';
import 'telemetry_frame.dart';

/// Byte offsets and scales of every field inside a telemetry payload.
///
/// Payload layout (big-endian, 52 bytes, CRC included):
///
/// | Offset | Size | Field     | Type | Scale    | Notes                          |
/// |--------|------|-----------|------|----------|--------------------------------|
/// | 0      | 1    | version   | u8   | —        | Format version (currently 1)   |
/// | 1      | 1    | flags     | u8   | bitfield | See [FrameFlags]               |
/// | 2      | 2    | seq       | u16  | —        | Rolling sequence number        |
/// | 4      | 4    | gpsLat    | i32  | 1e-7 deg | WGS84, positive North          |
/// | 8      | 4    | gpsLon    | i32  | 1e-7 deg | WGS84, positive East           |
/// | 12     | 4    | gpsAlt    | i32  | cm       | MSL altitude                   |
/// | 16     | 4    | baroAlt   | i32  | cm       | Above launch site              |
/// | 20     | 2    | velN      | i16  | cm/s     | NED: North                     |
/// | 22     | 2    | velE      | i16  | cm/s     | NED: East                      |
/// | 24     | 2    | velD      | i16  | cm/s     | NED: Down (positive down)      |
/// | 26     | 2    | accelX    | i16  | mg       | Body frame                     |
/// | 28     | 2    | accelY    | i16  | mg       | Body frame                     |
/// | 30     | 2    | accelZ    | i16  | mg       | Body frame, longitudinal       |
/// | 32     | 2    | gyroX     | i16  | centidps | Centi-degrees per second       |
/// | 34     | 2    | gyroY     | i16  | centidps |                                |
/// | 36     | 2    | gyroZ     | i16  | centidps | Longitudinal (±327 dps)        |
/// | 38     | 2    | heading   | u16  | 0.01 deg | Compass, [0, 360)              |
/// | 40     | 2    | roll      | i16  | centideg | Spin about longitudinal axis   |
/// | 42     | 2    | pitch     | i16  | centideg | Tilt from vertical             |
/// | 44     | 2    | yaw       | i16  | centideg | Nose heading, [-180, 180]      |
/// | 46     | 2    | battery   | u16  | mV       | Pack voltage                   |
/// | 48     | 2    | hall      | u16  | raw ADC  | Breakaway wire sensor (~2-3k)  |
/// | 50     | 1    | fsmState  | u8   | enum     | See [FsmState]                 |
/// | 51     | 2    | crc       | u16  | —        | CRC16-CCITT over bytes 0..50   |
abstract final class TelemetryLayout {
  /// Current wire format version emitted by encoders.
  static const int version = 1;

  static const int offsetVersion = 0;
  static const int offsetFlags = 1;
  static const int offsetSeq = 2;
  static const int offsetGpsLat = 4;
  static const int offsetGpsLon = 8;
  static const int offsetGpsAlt = 12;
  static const int offsetBaroAlt = 16;
  static const int offsetVelN = 20;
  static const int offsetVelE = 22;
  static const int offsetVelD = 24;
  static const int offsetAccelX = 26;
  static const int offsetAccelY = 28;
  static const int offsetAccelZ = 30;
  static const int offsetGyroX = 32;
  static const int offsetGyroY = 34;
  static const int offsetGyroZ = 36;
  static const int offsetHeading = 38;
  static const int offsetRoll = 40;
  static const int offsetPitch = 42;
  static const int offsetYaw = 44;
  static const int offsetBattery = 46;
  static const int offsetHall = 48;
  static const int offsetFsmState = 50;

  /// Offset of the trailing CRC16 field inside the payload.
  static const int offsetCrc = payloadCrcOffset;

  /// Fixed-point scale: degrees stored as 1e-7 deg units.
  static const double latLonScale = 1e-7;

  /// Fixed-point scale: velocities stored in cm/s.
  static const double velocityScale = 0.01;

  /// Fixed-point scale: accelerations stored in milli-g.
  static const double accelScaleMg = 0.00980665;

  /// Fixed-point scale: gyro rates stored in centi-degrees/s (±327.67 dps).
  static const double gyroScale = 0.01;

  /// Fixed-point scale: heading stored in centi-degrees.
  static const double angleScale = 0.01;
}

/// CRC offset derived from the framing constants so layout and framing can
/// never drift apart.
const int payloadCrcOffset = TelemetryFraming.payloadLength - 2;

/// Computes CRC16-CCITT (poly 0x1021, init 0xFFFF, no reflection, no xor-out)
/// over `bytes[start]` .. `bytes[end - 1]`.
int crc16CCITT(Uint8List bytes, [int start = 0, int? end]) {
  final last = end ?? bytes.length;
  var crc = 0xFFFF;
  for (var i = start; i < last; i++) {
    crc ^= bytes[i] << 8;
    for (var bit = 0; bit < 8; bit++) {
      crc = (crc & 0x8000) != 0 ? (crc << 1) ^ 0x1021 : crc << 1;
      crc &= 0xFFFF;
    }
  }
  return crc;
}

/// Encodes [TelemetryFrame]s to and from raw payload bytes.
abstract final class FrameCodec {
  /// Serializes [frame] into a complete payload (CRC appended).
  ///
  /// Continuous fields are quantized to their wire fixed-point scales; values
  /// outside the representable range are clamped rather than wrapped (roll
  /// wraps at ±327.67°, latitudes at the poles, longitudes at ±180°, heading
  /// modulo 360°).
  static Uint8List encode(TelemetryFrame frame) {
    final b = ByteData(TelemetryFraming.payloadLength);

    b.setUint8(TelemetryLayout.offsetVersion, TelemetryLayout.version);
    b.setUint8(TelemetryLayout.offsetFlags, frame.flags);
    b.setUint16(TelemetryLayout.offsetSeq, _clampU16(frame.sequence));
    b.setInt32(
      TelemetryLayout.offsetGpsLat,
      _clampI32((frame.latitude.clamp(-90.0, 90.0) / TelemetryLayout.latLonScale).round()),
    );
    b.setInt32(
      TelemetryLayout.offsetGpsLon,
      _clampI32((frame.longitude.clamp(-180.0, 180.0) / TelemetryLayout.latLonScale).round()),
    );
    b.setInt32(
      TelemetryLayout.offsetGpsAlt,
      _clampI32((frame.gpsAltitude * 100).round()),
    );
    b.setInt32(
      TelemetryLayout.offsetBaroAlt,
      _clampI32((frame.baroAltitude * 100).round()),
    );
    b.setInt16(
      TelemetryLayout.offsetVelN,
      _clampI16((frame.velocityNorth / TelemetryLayout.velocityScale).round()),
    );
    b.setInt16(
      TelemetryLayout.offsetVelE,
      _clampI16((frame.velocityEast / TelemetryLayout.velocityScale).round()),
    );
    b.setInt16(
      TelemetryLayout.offsetVelD,
      _clampI16((frame.velocityDown / TelemetryLayout.velocityScale).round()),
    );
    b.setInt16(
      TelemetryLayout.offsetAccelX,
      _clampI16((frame.accelX / TelemetryLayout.accelScaleMg).round()),
    );
    b.setInt16(
      TelemetryLayout.offsetAccelY,
      _clampI16((frame.accelY / TelemetryLayout.accelScaleMg).round()),
    );
    b.setInt16(
      TelemetryLayout.offsetAccelZ,
      _clampI16((frame.accelZ / TelemetryLayout.accelScaleMg).round()),
    );
    b.setInt16(
      TelemetryLayout.offsetGyroX,
      _clampI16((frame.gyroX / TelemetryLayout.gyroScale).round()),
    );
    b.setInt16(
      TelemetryLayout.offsetGyroY,
      _clampI16((frame.gyroY / TelemetryLayout.gyroScale).round()),
    );
    b.setInt16(
      TelemetryLayout.offsetGyroZ,
      _clampI16((frame.gyroZ / TelemetryLayout.gyroScale).round()),
    );
    b.setUint16(
      TelemetryLayout.offsetHeading,
      _clampU16((((frame.heading % 360) + 360) % 360 / TelemetryLayout.angleScale).round()),
    );
    b.setInt16(
      TelemetryLayout.offsetRoll,
      _clampI16((frame.roll / TelemetryLayout.angleScale).round()),
    );
    b.setInt16(
      TelemetryLayout.offsetPitch,
      _clampI16((frame.pitch / TelemetryLayout.angleScale).round()),
    );
    b.setInt16(
      TelemetryLayout.offsetYaw,
      _clampI16((frame.yaw / TelemetryLayout.angleScale).round()),
    );
    b.setUint16(
      TelemetryLayout.offsetBattery,
      _clampU16((frame.batteryVoltage * 1000).round()),
    );
    b.setUint16(TelemetryLayout.offsetHall, _clampU16(frame.hallRaw));
    b.setUint8(TelemetryLayout.offsetFsmState, frame.fsmStateId);

    final bytes = b.buffer.asUint8List();
    final crc = crc16CCITT(bytes, 0, payloadCrcOffset);
    b.setUint16(payloadCrcOffset, crc);
    return bytes;
  }

  /// Builds a complete wire packet (sync word + payload) for [frame].
  static Uint8List encodePacket(TelemetryFrame frame) {
    final payload = encode(frame);
    final packet = Uint8List(TelemetryFraming.totalPacketLength);
    packet[0] = TelemetryFraming.startByte0;
    packet[1] = TelemetryFraming.startByte1;
    packet.setAll(TelemetryFraming.startWordLength, payload);
    return packet;
  }

  /// Decodes a raw payload (as carried by a [TelemetryPacket]) into a frame.
  ///
  /// Auto-detects the payload generation by length: the current format
  /// ([TelemetryFraming.payloadLength] bytes) or the legacy v1.0 52-byte
  /// layout used before the hall sensor was widened to u16.
  ///
  /// Returns `null` for wrong lengths, unknown versions or CRC mismatches.
  static TelemetryFrame? decode(Uint8List payload, {required int receivedAtMs}) {
    if (payload.length == TelemetryFraming.payloadLength) {
      return _decodeCurrent(payload, receivedAtMs);
    }
    if (payload.length == 52) {
      return _decodeLegacy52(payload, receivedAtMs);
    }
    return null;
  }

  static TelemetryFrame? _decodeCurrent(Uint8List payload, int receivedAtMs) {
    final b = ByteData.sublistView(payload);
    if (b.getUint8(TelemetryLayout.offsetVersion) != TelemetryLayout.version) {
      return null;
    }
    if (b.getUint16(payloadCrcOffset) !=
        crc16CCITT(payload, 0, payloadCrcOffset)) {
      return null;
    }
    final lat =
        b.getInt32(TelemetryLayout.offsetGpsLat) * TelemetryLayout.latLonScale;
    if (lat.isNaN) return null;

    return TelemetryFrame(
      receivedAtMs: receivedAtMs,
      version: b.getUint8(TelemetryLayout.offsetVersion),
      flags: b.getUint8(TelemetryLayout.offsetFlags),
      sequence: b.getUint16(TelemetryLayout.offsetSeq),
      latitude: lat,
      longitude: b.getInt32(TelemetryLayout.offsetGpsLon) * TelemetryLayout.latLonScale,
      gpsAltitude: b.getInt32(TelemetryLayout.offsetGpsAlt) / 100,
      baroAltitude: b.getInt32(TelemetryLayout.offsetBaroAlt) / 100,
      velocityNorth:
          b.getInt16(TelemetryLayout.offsetVelN) * TelemetryLayout.velocityScale,
      velocityEast:
          b.getInt16(TelemetryLayout.offsetVelE) * TelemetryLayout.velocityScale,
      velocityDown:
          b.getInt16(TelemetryLayout.offsetVelD) * TelemetryLayout.velocityScale,
      accelX: b.getInt16(TelemetryLayout.offsetAccelX) * TelemetryLayout.accelScaleMg,
      accelY: b.getInt16(TelemetryLayout.offsetAccelY) * TelemetryLayout.accelScaleMg,
      accelZ: b.getInt16(TelemetryLayout.offsetAccelZ) * TelemetryLayout.accelScaleMg,
      gyroX: b.getInt16(TelemetryLayout.offsetGyroX) * TelemetryLayout.gyroScale,
      gyroY: b.getInt16(TelemetryLayout.offsetGyroY) * TelemetryLayout.gyroScale,
      gyroZ: b.getInt16(TelemetryLayout.offsetGyroZ) * TelemetryLayout.gyroScale,
      heading: b.getUint16(TelemetryLayout.offsetHeading) * TelemetryLayout.angleScale,
      roll: b.getInt16(TelemetryLayout.offsetRoll) * TelemetryLayout.angleScale,
      pitch: b.getInt16(TelemetryLayout.offsetPitch) * TelemetryLayout.angleScale,
      yaw: b.getInt16(TelemetryLayout.offsetYaw) * TelemetryLayout.angleScale,
      batteryVoltage: b.getUint16(TelemetryLayout.offsetBattery) / 1000,
      hallRaw: b.getUint16(TelemetryLayout.offsetHall),
      fsmStateId: b.getUint8(TelemetryLayout.offsetFsmState),
    );
  }

  /// Legacy 52-byte layout: identical except `hall` is a 0/1 byte at 48,
  /// `fsmState` at 49 and the CRC at 50.
  static TelemetryFrame? _decodeLegacy52(Uint8List payload, int receivedAtMs) {
    const legacyCrcOffset = 50;
    const legacyFsmOffset = 49;
    const legacyHallOffset = 48;

    final b = ByteData.sublistView(payload);
    if (b.getUint8(TelemetryLayout.offsetVersion) != 1) return null;
    if (b.getUint16(legacyCrcOffset) != crc16CCITT(payload, 0, legacyCrcOffset)) {
      return null;
    }

    return TelemetryFrame(
      receivedAtMs: receivedAtMs,
      version: b.getUint8(TelemetryLayout.offsetVersion),
      flags: b.getUint8(TelemetryLayout.offsetFlags),
      sequence: b.getUint16(TelemetryLayout.offsetSeq),
      latitude: b.getInt32(TelemetryLayout.offsetGpsLat) * TelemetryLayout.latLonScale,
      longitude: b.getInt32(TelemetryLayout.offsetGpsLon) * TelemetryLayout.latLonScale,
      gpsAltitude: b.getInt32(TelemetryLayout.offsetGpsAlt) / 100,
      baroAltitude: b.getInt32(TelemetryLayout.offsetBaroAlt) / 100,
      velocityNorth:
          b.getInt16(TelemetryLayout.offsetVelN) * TelemetryLayout.velocityScale,
      velocityEast:
          b.getInt16(TelemetryLayout.offsetVelE) * TelemetryLayout.velocityScale,
      velocityDown:
          b.getInt16(TelemetryLayout.offsetVelD) * TelemetryLayout.velocityScale,
      accelX: b.getInt16(TelemetryLayout.offsetAccelX) * TelemetryLayout.accelScaleMg,
      accelY: b.getInt16(TelemetryLayout.offsetAccelY) * TelemetryLayout.accelScaleMg,
      accelZ: b.getInt16(TelemetryLayout.offsetAccelZ) * TelemetryLayout.accelScaleMg,
      gyroX: b.getInt16(TelemetryLayout.offsetGyroX) * TelemetryLayout.gyroScale,
      gyroY: b.getInt16(TelemetryLayout.offsetGyroY) * TelemetryLayout.gyroScale,
      gyroZ: b.getInt16(TelemetryLayout.offsetGyroZ) * TelemetryLayout.gyroScale,
      heading: b.getUint16(TelemetryLayout.offsetHeading) * TelemetryLayout.angleScale,
      roll: b.getInt16(TelemetryLayout.offsetRoll) * TelemetryLayout.angleScale,
      pitch: b.getInt16(TelemetryLayout.offsetPitch) * TelemetryLayout.angleScale,
      yaw: b.getInt16(TelemetryLayout.offsetYaw) * TelemetryLayout.angleScale,
      batteryVoltage: b.getUint16(TelemetryLayout.offsetBattery) / 1000,
      // Legacy hall was a 0/1 flag; map onto the raw scale for the UI.
      hallRaw: b.getUint8(legacyHallOffset) != 0 ? 2950 : 2500,
      fsmStateId: b.getUint8(legacyFsmOffset),
    );
  }

  /// Verifies the trailing CRC of a raw payload (current or legacy length)
  /// without fully decoding it.
  static bool verifyCrc(Uint8List payload) {
    if (payload.length == TelemetryFraming.payloadLength) {
      final b = ByteData.sublistView(payload);
      return b.getUint16(payloadCrcOffset) ==
          crc16CCITT(payload, 0, payloadCrcOffset);
    }
    if (payload.length == 52) {
      const legacyCrcOffset = 50;
      final b = ByteData.sublistView(payload);
      return b.getUint16(legacyCrcOffset) ==
          crc16CCITT(payload, 0, legacyCrcOffset);
    }
    return false;
  }

  static int _clampI16(int v) => v.clamp(-0x8000, 0x7FFF);
  static int _clampU16(int v) => v.clamp(0, 0xFFFF);
  static int _clampI32(int v) => v.clamp(-0x80000000, 0x7FFFFFFF);
}
