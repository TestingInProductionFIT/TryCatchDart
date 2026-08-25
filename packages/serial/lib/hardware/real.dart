import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_libserialport/flutter_libserialport.dart';

import '../constants.dart';

/// Physical hardware implementation of serial port communication.
///
/// Directly manages native [SerialPort] handles, asynchronous [SerialPortReader]
/// stream listening, and hardware configuration applying [SerialHardwareConfig].
class RealSerialPort {
  SerialPort? _port;
  SerialPortReader? _reader;
  StreamSubscription<Uint8List>? _readerSubscription;

  /// Broadcast controller emitting raw incoming byte chunks from the physical port.
  final StreamController<Uint8List> _byteStreamController =
      StreamController<Uint8List>.broadcast();

  /// Stream of incoming raw byte chunks from the physical serial connection.
  Stream<Uint8List> get byteStream => _byteStreamController.stream;

  /// Whether a physical serial connection is currently open.
  bool get isConnected => _port != null && _port!.isOpen;

  /// List of detected physical serial ports available on the host OS.
  static List<String> get availablePorts => SerialPort.availablePorts;

  /// Opens and configures the physical serial port identified by [portName].
  bool connect(String portName) {
    disconnect();

    try {
      _port = SerialPort(portName);
      if (!_port!.openReadWrite()) {
        disconnect();
        return false;
      }

      // Configure hardware parameters from centralized constants
      _port!.config.baudRate = SerialHardwareConfig.baudRate;
      _port!.config.parity = SerialHardwareConfig.parity;
      _port!.config.stopBits = SerialHardwareConfig.stopBits;
      _port!.config.bits = SerialHardwareConfig.dataBits;

      // Attach native asynchronous stream reader
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

  /// Closes the physical serial port and cancels active reader threads.
  void disconnect() {
    _readerSubscription?.cancel();
    _readerSubscription = null;

    try {
      _reader?.close();
    } catch (_) {}
    _reader = null;

    if (_port != null) {
      try {
        if (_port!.isOpen) {
          _port!.close();
        }
        _port!.dispose();
      } catch (_) {}
      _port = null;
    }
  }

  /// Transmits raw [bytes] to the connected hardware port.
  bool sendBytes(Uint8List bytes) {
    if (!isConnected) return false;

    try {
      return _port!.write(bytes) == bytes.length;
    } catch (_) {
      disconnect();
      return false;
    }
  }
}
