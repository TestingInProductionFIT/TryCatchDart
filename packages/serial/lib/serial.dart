/// Library for communicating over serial ports.
library;

export 'constants.dart';
export 'hardware/mock.dart';
export 'hardware/real.dart';
export 'io/file_parser.dart';
export 'io/packet_parser.dart';
export 'io/recorder.dart';
export 'worker/manager.dart';
export 'worker/protocol.dart';

import 'dart:async';
import 'dart:typed_data';

import 'hardware/mock.dart';
import 'hardware/real.dart';

/// Unified serial communication service coordinating physical hardware
/// ([RealSerialPort]) and simulated telemetry ([MockSerialPort]).
class SerialService {
  final RealSerialPort _realPort = RealSerialPort();
  final MockSerialPort _mockPort = MockSerialPort();

  StreamSubscription<Uint8List>? _realSubscription;
  StreamSubscription<Uint8List>? _mockSubscription;
  bool _isMockActive = false;

  final StreamController<Uint8List> _byteStreamController =
      StreamController<Uint8List>.broadcast();

  /// Stream of raw incoming [Uint8List] byte chunks from the active port.
  Stream<Uint8List> get byteStream => _byteStreamController.stream;

  /// Returns a combined list of all detected physical ports and the virtual MOCK port.
  static List<String> get availablePorts => [
    MockSerialPort.portName,
    ...RealSerialPort.availablePorts,
  ];

  /// Whether a connection is currently active (physical or virtual).
  bool get isConnected =>
      _isMockActive ? _mockPort.isConnected : _realPort.isConnected;

  /// Establishes a serial connection to [portName] (physical COM port or virtual MOCK).
  bool connect(String portName) {
    disconnect();

    if (portName == MockSerialPort.portName) {
      _isMockActive = true;
      _mockSubscription = _mockPort.byteStream.listen((data) {
        if (_isMockActive) {
          _byteStreamController.add(data);
        }
      });
      return _mockPort.connect();
    }

    _isMockActive = false;
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
      _isMockActive = false;
    } else {
      _realPort.disconnect();
    }
  }

  /// Transmits raw [bytes] over the active connection.
  bool sendBytes(Uint8List bytes) {
    if (!isConnected) return false;
    return _isMockActive
        ? _mockPort.sendBytes(bytes)
        : _realPort.sendBytes(bytes);
  }
}
