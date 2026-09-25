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
  static const int payloadLength = 52;

  /// Total packet length in bytes (sync word + payload).
  static const int totalPacketLength = startWordLength + payloadLength;
}

/// Centralized hardware serial port configuration.
///
/// The modem-line / flow-control policy below is load-bearing: the LoRa
/// ground-station dongles are 3-wire (TX/RX/GND) MCU adapters. Leaving the
/// OS/driver defaults in place asserts DTR/RTS or enables RTS/CTS flow
/// control on some ARM builds, which holds the MCU in reset (or stalls its
/// TX on a floating CTS) until the adapter is physically re-enumerated
/// (unplug/replug). Keep every value at "off / ignore / none".
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

  /// Flow-control preset (`SerialPortFlowControl.none` = 0).
  ///
  /// The firmware speaks plain 8N1 with no flow control; anything else
  /// stalls TX on unwired CTS/DSR lines. See the class doc.
  static const int flowControl = 0;

  /// RTS pin behaviour (`SerialPortRts.off` = 0).
  ///
  /// Asserted RTS resets ESP32-class LoRa MCUs via the auto-reset capacitor
  /// network. Must stay off.
  static const int rts = 0;

  /// CTS pin behaviour (`SerialPortCts.ignore` = 0).
  static const int cts = 0;

  /// DTR pin behaviour (`SerialPortDtr.off` = 0).
  ///
  /// Asserted DTR holds common USB-UART LoRa adapters in reset. Must stay
  /// off.
  static const int dtr = 0;

  /// DSR pin behaviour (`SerialPortDsr.ignore` = 0).
  static const int dsr = 0;

  /// XON/XOFF software flow control (`SerialPortXonXoff.disabled` = 0).
  static const int xonXoff = 0;
}
