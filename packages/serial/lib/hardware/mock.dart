import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import '../constants.dart';

/// A mock implementation of a serial communication service.
///
/// Simulates incoming binary telemetry data without requiring physical
/// serial hardware or COM ports. Useful for UI development, automated
/// testing, and offline demonstrations.
///
/// Emits properly framed packets using configuration from [TelemetryFraming].
class MockSerialPort {
  Timer? _mockTimer;
  bool _isConnected = false;

  /// Identifier used to select the mock port in UI dropdowns.
  static String get portName => 'MOCK';

  /// Broadcast stream controller emitting simulated incoming byte chunks.
  final StreamController<Uint8List> _byteStreamController =
      StreamController<Uint8List>.broadcast();

  /// Stream of incoming simulated telemetry byte buffers.
  Stream<Uint8List> get byteStream => _byteStreamController.stream;

  /// Whether the mock connection is currently active and producing data.
  bool get isConnected => _isConnected;

  /// Starts the mock connection and begins emitting randomized packets.
  ///
  /// Emits one properly framed packet per millisecond to simulate
  /// a high-frequency telemetry stream.
  bool connect() {
    disconnect();
    _isConnected = true;
    final random = Random();

    _mockTimer = Timer.periodic(const Duration(milliseconds: 100), (_) {
      if (!_isConnected) return;

      // Build a valid framed packet the parser can decode.
      final packet = Uint8List(TelemetryFraming.totalPacketLength);
      packet[0] = TelemetryFraming.startByte0;
      packet[1] = TelemetryFraming.startByte1;
      for (
        int i = TelemetryFraming.startWordLength;
        i < TelemetryFraming.totalPacketLength;
        i++
      ) {
        packet[i] = random.nextInt(256);
      }

      _byteStreamController.add(packet);
    });

    return true;
  }

  /// Terminates the mock connection and cancels the data generation timer.
  void disconnect() {
    _isConnected = false;
    _mockTimer?.cancel();
    _mockTimer = null;
  }

  /// Simulates transmitting [bytes] across the mock connection.
  ///
  /// Returns `true` if connected, simulating successful transmission.
  bool sendBytes(Uint8List bytes) {
    if (!_isConnected) return false;
    // Acknowledge sent bytes in mock mode
    return true;
  }
}
