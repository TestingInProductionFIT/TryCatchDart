/// Library for communicating over serial ports.
library;

export 'constants.dart';
export 'hardware/mock.dart';
export 'hardware/mock_bq.dart';
export 'hardware/real.dart';
export 'io/file_parser.dart';
export 'io/packet_parser.dart';
export 'io/recorder.dart';
export 'io/recording_file.dart';
export 'telemetry/frame_codec.dart';
export 'telemetry/flight_simulator.dart';
export 'telemetry/telemetry_frame.dart';
export 'worker/manager.dart';
export 'worker/protocol.dart';

import 'dart:async';
import 'dart:typed_data';

import 'hardware/mock.dart';
import 'hardware/mock_bq.dart';
import 'hardware/real.dart';

/// Unified serial communication service coordinating physical hardware
/// ([RealSerialPort]) and simulated telemetry ([MockSerialPort],
/// [MockBqSerialPort]).
class SerialService {
  final RealSerialPort _realPort = RealSerialPort();
  final MockSerialPort _mockPort = MockSerialPort();
  final MockBqSerialPort _mockBqPort = MockBqSerialPort();

  StreamSubscription<Uint8List>? _realSubscription;
  StreamSubscription<Uint8List>? _mockSubscription;

  /// Name of the active mock port ([MockSerialPort.portName] /
  /// [MockBqSerialPort.portName]), or `null` when the real port is active.
  String? _activeMockName;

  bool get _isMockActive => _activeMockName != null;

  final StreamController<Uint8List> _byteStreamController =
      StreamController<Uint8List>.broadcast();

  /// Stream of raw incoming [Uint8List] byte chunks from the active port.
  Stream<Uint8List> get byteStream => _byteStreamController.stream;

  /// Returns a combined list of all detected physical ports and the virtual
  /// mock ports (MOCK + MOCK-BQ).
  static List<String> get availablePorts => [
    MockSerialPort.portName,
    MockBqSerialPort.portName,
    ...RealSerialPort.availablePorts,
  ];

  /// Whether a connection is currently active (physical or virtual).
  bool get isConnected {
    if (_activeMockName == MockBqSerialPort.portName) {
      return _mockBqPort.isConnected;
    }
    if (_activeMockName != null) return _mockPort.isConnected;
    return _realPort.isConnected;
  }

  /// Establishes a serial connection to [portName] (physical COM port or
  /// virtual MOCK / MOCK-BQ).
  bool connect(String portName) {
    disconnect();

    if (portName == MockSerialPort.portName ||
        portName == MockBqSerialPort.portName) {
      _activeMockName = portName;
      final mockStream = portName == MockBqSerialPort.portName
          ? _mockBqPort.byteStream
          : _mockPort.byteStream;
      _mockSubscription = mockStream.listen((data) {
        if (_isMockActive) {
          _byteStreamController.add(data);
        }
      });
      return portName == MockBqSerialPort.portName
          ? _mockBqPort.connect()
          : _mockPort.connect();
    }

    _activeMockName = null;
    _realSubscription = _realPort.byteStream.listen((data) {
      if (!_isMockActive) {
        _byteStreamController.add(data);
      }
    });

    final ok = _realPort.connect(portName);
    if (!ok) {
      disconnect();
    }
    return ok;
  }

  /// Disconnects the active serial connection and resets stream forwarders.
  void disconnect() {
    _mockSubscription?.cancel();
    _mockSubscription = null;
    _realSubscription?.cancel();
    _realSubscription = null;

    if (_isMockActive) {
      _mockPort.disconnect();
      _mockBqPort.disconnect();
      _activeMockName = null;
    } else {
      _realPort.disconnect();
    }
  }

  /// Transmits raw [bytes] over the active connection.
  bool sendBytes(Uint8List bytes) {
    if (!isConnected) return false;
    if (_activeMockName == MockBqSerialPort.portName) {
      return _mockBqPort.sendBytes(bytes);
    }
    return _isMockActive
        ? _mockPort.sendBytes(bytes)
        : _realPort.sendBytes(bytes);
  }
}
