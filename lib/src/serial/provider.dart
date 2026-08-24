import 'dart:typed_data';

import 'package:flutter_libserialport/flutter_libserialport.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:serial/serial.dart';

/// Provider for the singleton [SerialService] instance.
///
/// Ensures any active serial port is cleanly disconnected and released
/// when this provider is disposed.
final serialServiceProvider = Provider<SerialService>((ref) {
  final service = SerialService();
  ref.onDispose(() => service.disconnect());
  return service;
});

/// Stream provider delivering chunks of incoming raw bytes as they arrive
/// from the connected serial port.
final rawBytesStreamProvider = StreamProvider.autoDispose<Uint8List>((ref) {
  final service = ref.watch(serialServiceProvider);
  return service.byteStream;
});

/// Immutable state representing the current serial port configuration and connection status.
class SerialConnectionState {
  /// List of detected serial ports available for connection.
  final List<String> availablePorts;

  /// The currently selected serial port identifier.
  final String? selectedPort;

  /// Configured baud rate (defaults to `115200`).
  final int baudRate;

  /// Parity setting (e.g. [SerialPortParity.none]).
  final int parity;

  /// Number of stop bits (e.g. `1` or `2`).
  final int stopBits;

  /// Whether a connection is currently open and active.
  final bool isConnected;

  const SerialConnectionState({
    this.availablePorts = const [],
    this.selectedPort,
    this.baudRate = 115200,
    this.parity = SerialPortParity.none,
    this.stopBits = 1,
    this.isConnected = false,
  });

  /// Creates a copy of this state with the given fields replaced by new values.
  SerialConnectionState copyWith({
    List<String>? availablePorts,
    String? selectedPort,
    int? baudRate,
    int? parity,
    int? stopBits,
    bool? isConnected,
  }) {
    return SerialConnectionState(
      availablePorts: availablePorts ?? this.availablePorts,
      selectedPort: selectedPort ?? this.selectedPort,
      baudRate: baudRate ?? this.baudRate,
      parity: parity ?? this.parity,
      stopBits: stopBits ?? this.stopBits,
      isConnected: isConnected ?? this.isConnected,
    );
  }
}

/// Provider exposing the [SerialController] notifier and its [SerialConnectionState].
final serialControllerProvider =
    NotifierProvider<SerialController, SerialConnectionState>(
      SerialController.new,
    );

/// Riverpod controller managing serial port discovery, configuration settings,
/// and connection lifecycle actions.
class SerialController extends Notifier<SerialConnectionState> {
  @override
  SerialConnectionState build() {
    // Asynchronously query available ports on initial startup
    Future.microtask(() => refreshPorts());

    return const SerialConnectionState();
  }

  /// Scans the system for connected serial devices and updates [state.availablePorts].
  void refreshPorts() {
    state = state.copyWith(availablePorts: SerialService.availablePorts);
  }

  /// Updates the target [port]. Safely disconnects any active connection before switching.
  void setPort(String? port) {
    ref.read(serialServiceProvider).disconnect();
    state = state.copyWith(selectedPort: port, isConnected: false);
  }

  /// Updates the configured [baudRate].
  void setBaudRate(int baudRate) => state = state.copyWith(baudRate: baudRate);

  /// Updates the configured [parity].
  void setParity(int parity) => state = state.copyWith(parity: parity);

  /// Updates the configured [stopBits].
  void setStopBits(int stopBits) => state = state.copyWith(stopBits: stopBits);

  /// Initiates a serial connection using the currently selected port and settings.
  ///
  /// Returns `true` if the connection was established successfully.
  bool connect() {
    if (state.selectedPort == null) return false;

    final service = ref.read(serialServiceProvider);
    service.disconnect();

    final success = service.connect(
      state.selectedPort!,
      baudRate: state.baudRate,
      parity: state.parity,
      stopBits: state.stopBits,
    );

    state = state.copyWith(isConnected: success);
    return success;
  }

  /// Disconnects the active serial port and clears the selection state.
  void disconnect() {
    ref.read(serialServiceProvider).disconnect();
    state = state.copyWith(selectedPort: null, isConnected: false);
  }
}
