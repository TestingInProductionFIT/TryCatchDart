/// Shared telemetry packet framing and hardware serial configuration constants.
///
/// Used across both the background serial worker and the UI to ensure
/// consistent framing and hardware settings across the entire codebase.
library;

/// Centralized framing constants for packet decoding and mock generation.
abstract final class TelemetryFraming {
  /// First byte of the 2-byte sync / start word (MSB).
  static const int startByte0 = 0xAA;

  /// Second byte of the 2-byte sync / start word (LSB).
  static const int startByte1 = 0x55;

  /// Combined 16-bit start word (0xAA55).
  static const int startWord = (startByte0 << 8) | startByte1;

  /// Number of bytes in the sync word header.
  static const int startWordLength = 2;

  /// Number of telemetry payload bytes following the sync word.
  ///
  /// Includes the trailing 2-byte CRC16 — see `TelemetryLayout` in
  /// `telemetry/frame_codec.dart` for the byte-by-byte payload map.
  static const int payloadLength = 53;

  /// Total packet length in bytes (sync word + payload).
  static const int totalPacketLength = startWordLength + payloadLength;
}

/// Centralized hardware serial port configuration.
abstract final class SerialHardwareConfig {
  /// Communication speed in baud.
  static const int baudRate = 115200;

  /// Number of data bits per frame (typically 8).
  static const int dataBits = 8;

  /// Parity mode:
  /// - 0 = None
  /// - 1 = Odd
  /// - 2 = Even
  static const int parity = 0;

  /// Number of stop bits (typically 1 or 2).
  static const int stopBits = 1;
}
