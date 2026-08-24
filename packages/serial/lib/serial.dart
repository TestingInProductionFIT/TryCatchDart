library;

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_libserialport/flutter_libserialport.dart';

import 'mock.dart';

/// Service responsible for managing serial communication with physical COM ports
/// or a virtual simulated port.
///
/// Handles port discovery, hardware configuration (baud rate, parity, stop bits),
/// native asynchronous stream reading, and streaming of raw byte payloads.
class SerialService {
  SerialPort? _port;
  SerialPortReader? _reader;
  StreamSubscription<Uint8List>? _readerSubscription;
  StreamSubscription<Uint8List>? _mockSubscription;

  final MockSerialService _mockService = MockSerialService();
  bool _isMockActive = false;

  /// Broadcast controller for distributing raw incoming byte chunks to listeners.
  final StreamController<Uint8List> _byteStreamController =
      StreamController<Uint8List>.broadcast();

  /// Stream of raw incoming [Uint8List] byte chunks from the connected port.
  Stream<Uint8List> get byteStream => _byteStreamController.stream;

  /// Returns a list of all detected serial ports available on the system.
  static List<String> get availablePorts => [
    MockSerialService.portName,
    ...SerialPort.availablePorts,
  ];

  /// Whether a connection is currently active.
  bool get isConnected => _isMockActive
      ? _mockService.isConnected
      : (_port != null && _port!.isOpen);

  /// Establishes a serial connection to the specified [portName].
  ///
  /// Returns `true` if the connection succeeded, or `false` on failure.
  bool connect(
    String portName, {
    int baudRate = 115200,
    int parity = SerialPortParity.none,
    int stopBits = 1,
    int dataBits = 8,
  }) {
    // Ensure any existing connection is safely closed first
    disconnect();

    if (portName == MockSerialService.portName) {
      _isMockActive = true;

      // Forward stream events from mock service to the main stream controller
      _mockSubscription = _mockService.byteStream.listen((data) {
        if (_isMockActive) {
          _byteStreamController.add(data);
        }
      });

      return _mockService.connect();
    }

    // Real hardware connection path
    try {
      _port = SerialPort(portName);
      if (!_port!.openReadWrite()) {
        disconnect();
        return false;
      }

      // Apply serial port configuration parameters
      final config = _port!.config;
      config.baudRate = baudRate;
      config.parity = parity;
      config.stopBits = stopBits;
      config.bits = dataBits;
      _port!.config = config;

      // Attach native stream reader for asynchronous event-driven reads
      _reader = SerialPortReader(_port!);
      _readerSubscription = _reader!.stream.listen(
        (data) {
          if (data.isNotEmpty) {
            _byteStreamController.add(data);
          }
        },
        onError: (_) => disconnect(),
        onDone: () => disconnect(),
      );

      return true;
    } catch (_) {
      disconnect();
      return false;
    }
  }

  /// Disconnects the active serial connection and releases all resources.
  ///
  /// Strictly cancels stream subscriptions, closes native readers, closes ports, and resets internal state.
  void disconnect() {
    if (_isMockActive) {
      _mockSubscription?.cancel();
      _mockSubscription = null;
      _mockService.disconnect();
      _isMockActive = false;
    }

    // 1. Cancel the Dart stream subscription first
    _readerSubscription?.cancel();
    _readerSubscription = null;

    // 2. Close the native reader thread/resource
    try {
      _reader?.close();
    } catch (_) {}
    _reader = null;

    // 3. Finally close and dispose the hardware port handle
    if (_port != null) {
      try {
        if (_port!.isOpen) {
          _port!.close();
        }
        _port!.dispose();
      } catch (_) {
        // Suppress native disposal exceptions during teardown
      }
      _port = null;
    }
  }

  /// Transmits raw [bytes] over the active connection.
  ///
  /// Returns `true` if all bytes were successfully written, or `false` if not
  /// connected or if an error occurred during writing.
  bool sendBytes(Uint8List bytes) {
    if (!isConnected) return false;

    if (_isMockActive) {
      return _mockService.sendBytes(bytes);
    }

    try {
      return _port!.write(bytes) == bytes.length;
    } catch (_) {
      disconnect();
      return false;
    }
  }
}
