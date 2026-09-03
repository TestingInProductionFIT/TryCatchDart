import 'dart:async';
import 'dart:typed_data';

import '../telemetry/flight_simulator.dart';
import '../telemetry/frame_codec.dart';

/// A mock implementation of a serial communication service.
///
/// Simulates an incoming stream of realistic flight telemetry driven by
/// [FlightSimulator] without requiring physical serial hardware or COM ports.
/// Useful for UI development, automated testing, and offline demonstrations.
///
/// Every `connect()` starts a fresh simulated flight (GPS cold start → pad →
/// boost → coast → drogue → main → landed). Frames are emitted at 10 Hz as
/// properly framed wire packets.
class MockSerialPort {
  Timer? _mockTimer;
  bool _isConnected = false;
  FlightSimulator? _simulator;

  /// Identifier used to select the mock port in UI dropdowns.
  static String get portName => 'MOCK';

  /// Broadcast stream controller emitting simulated incoming byte chunks.
  final StreamController<Uint8List> _byteStreamController =
      StreamController<Uint8List>.broadcast();

  /// Stream of incoming simulated telemetry byte buffers.
  Stream<Uint8List> get byteStream => _byteStreamController.stream;

  /// Whether the mock connection is currently active and producing data.
  bool get isConnected => _isConnected;

  /// Starts the mock connection and begins emitting simulated flight frames.
  bool connect() {
    disconnect();
    _isConnected = true;
    _simulator = FlightSimulator();

    const tick = Duration(milliseconds: 100);
    _mockTimer = Timer.periodic(tick, (_) {
      if (!_isConnected) return;

      final frame = _simulator!.step(tick.inMilliseconds / 1000);
      _byteStreamController.add(FrameCodec.encodePacket(frame));
    });

    return true;
  }

  /// Terminates the mock connection and cancels the data generation timer.
  void disconnect() {
    _isConnected = false;
    _mockTimer?.cancel();
    _mockTimer = null;
    _simulator = null;
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
