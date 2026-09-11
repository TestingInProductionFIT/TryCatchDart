import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import '../telemetry/flight_simulator.dart';
import '../telemetry/frame_codec.dart';
import 'mock.dart';

/// Bad-quality mock cycle (@10 Hz): [onTicks] emitting ticks followed by
/// [offTicks] of total silence, repeating every
/// [onTicks] + [offTicks] ticks.
///
/// Defaults give ~10 s of normal MOCK traffic then ~5 s of complete link loss
/// every ~15 s, exercising the dead-reckoning gap filler, packet-rate decay,
/// and "Ns ago" link readouts without any radio hardware.
const int mockBqOnTicks = 100;
const int mockBqOffTicks = 50;

/// Total MOCK-BQ cycle length in 100 ms ticks (@10 Hz).
const int mockBqPeriodTicks = mockBqOnTicks + mockBqOffTicks;

/// Returns `true` when tick [tick] (0-based, 100 ms cadence) falls inside the
/// MOCK-BQ dropout window — i.e. nothing is emitted for that tick.
bool mockBqDropoutForTick(int tick) {
  final t = tick % mockBqPeriodTicks;
  return t >= mockBqOnTicks;
}

/// A bad-quality mock serial port for link-loss testing.
///
/// Mimics [MockSerialPort] (same [FlightSimulator] flight + same 20 s
/// unknown-traffic interference cycle) but cuts the link completely for
/// [mockBqOffTicks] ticks out of every [mockBqPeriodTicks]-tick cycle
/// (~5 s of silence every ~15 s).
///
/// The simulator keeps stepping through the dropout (the rocket keeps flying
/// while the link is dead), so resumption shows a time jump — exactly like a
/// real link outage. During the dropout no packet, noise, or CRC-corrupted
/// clone is emitted.
class MockBqSerialPort {
  Timer? _mockTimer;
  bool _isConnected = false;
  FlightSimulator? _simulator;
  int _tick = 0;
  final math.Random _random = math.Random();

  /// Identifier used to select the bad-quality mock port in UI dropdowns.
  static String get portName => 'MOCK-BQ';

  /// Broadcast stream controller emitting simulated incoming byte chunks.
  final StreamController<Uint8List> _byteStreamController =
      StreamController<Uint8List>.broadcast();

  /// Stream of incoming simulated telemetry byte buffers.
  Stream<Uint8List> get byteStream => _byteStreamController.stream;

  /// Whether the mock connection is currently active and producing data.
  bool get isConnected => _isConnected;

  /// Starts the mock connection and begins emitting simulated flight frames
  /// with periodic dropouts (see [mockBqDropoutForTick]).
  bool connect() {
    disconnect();
    _isConnected = true;
    _simulator = FlightSimulator();
    _tick = 0;

    const tick = Duration(milliseconds: 100);
    _mockTimer = Timer.periodic(tick, (_) {
      if (!_isConnected) return;

      // Always advance the flight so the dropout looks like a real outage
      // (time jump on resume) rather than a paused simulator.
      final frame = _simulator!.step(tick.inMilliseconds / 1000);
      final currentTick = _tick++;
      if (mockBqDropoutForTick(currentTick)) return;

      final packet = FrameCodec.encodePacket(frame);
      _byteStreamController.add(packet);

      // Same cyclic unknown traffic as the clean MOCK port.
      final noise = mockInterferenceBytes(currentTick, _random);
      if (noise != null) _byteStreamController.add(noise);
      if (mockPhaseForTick(currentTick) == MockInterferencePhase.heavy &&
          currentTick % 5 == 0) {
        // Bit-flipped clone: frames but fails CRC (exercises crcErrorBytes).
        final corrupted = Uint8List.fromList(packet);
        corrupted[10] ^= 0xFF;
        _byteStreamController.add(corrupted);
      }
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
