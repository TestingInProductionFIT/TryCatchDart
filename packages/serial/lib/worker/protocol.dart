import 'dart:typed_data';

import '../constants.dart';

// ─── Commands (UI → Serial Worker Isolate) ───────────────────────────────────

/// Base class for all commands sent to the serial worker isolate.
sealed class SerialCommand {
  const SerialCommand();
}

/// Open a serial port using centralized hardware settings from [SerialHardwareConfig].
class ConnectCommand extends SerialCommand {
  final String port;

  const ConnectCommand(this.port);
}

/// Close the active serial port connection.
class DisconnectCommand extends SerialCommand {
  const DisconnectCommand();
}

/// Request a scan of available COM ports and simulated ports.
class ListPortsCommand extends SerialCommand {
  const ListPortsCommand();
}

/// Transmit raw [bytes] to the rocket over the active connection.
///
/// Used by the control panel for arming / deployment commands defined entirely
/// on the UI side as data.
class SendBytesCommand extends SerialCommand {
  final Uint8List bytes;

  const SendBytesCommand(this.bytes);
}

/// Start recording parsed telemetry packets to the given file path.
class StartRecordingCommand extends SerialCommand {
  final String filePath;
  const StartRecordingCommand({required this.filePath});
}

/// Stop the current recording session and flush to disk.
class StopRecordingCommand extends SerialCommand {
  const StopRecordingCommand();
}

// ─── Events (Serial Worker Isolate → UI) ─────────────────────────────────────

/// Base class for all events emitted from the serial worker isolate.
sealed class SerialEvent {}

/// Emitted whenever a full [TelemetryPacket] is received and parsed.
class PacketReceivedEvent extends SerialEvent {
  final TelemetryPacket packet;
  PacketReceivedEvent(this.packet);
}

/// Emitted with the list of detected serial ports.
class PortListEvent extends SerialEvent {
  final List<String> ports;
  PortListEvent(this.ports);
}

/// Emitted when connection status or recording state changes.
class StatusChangedEvent extends SerialEvent {
  final SerialWorkerStatus status;
  StatusChangedEvent(this.status);
}

/// Emitted when a serial or parsing error occurs.
class ErrorEvent extends SerialEvent {
  final String message;
  ErrorEvent(this.message);
}

// ─── Data Models ─────────────────────────────────────────────────────────────

/// Immutable snapshot of the serial worker's operational state.
class SerialWorkerStatus {
  final bool isConnected;
  final String? connectedPort;
  final bool isRecording;
  final String? recordingPath;

  const SerialWorkerStatus({
    this.isConnected = false,
    this.connectedPort,
    this.isRecording = false,
    this.recordingPath,
  });

  static const _absent = Object();

  SerialWorkerStatus copyWith({
    bool? isConnected,
    Object? connectedPort = _absent,
    bool? isRecording,
    Object? recordingPath = _absent,
  }) {
    return SerialWorkerStatus(
      isConnected: isConnected ?? this.isConnected,
      connectedPort: identical(connectedPort, _absent)
          ? this.connectedPort
          : connectedPort as String?,
      isRecording: isRecording ?? this.isRecording,
      recordingPath: identical(recordingPath, _absent)
          ? this.recordingPath
          : recordingPath as String?,
    );
  }
}

/// A parsed telemetry frame consisting of a timestamp and raw payload bytes.
class TelemetryPacket {
  /// Milliseconds since Unix epoch when packet was parsed.
  final int receivedAtMs;

  /// The raw payload bytes (excluding the start word header).
  final Uint8List rawData;

  const TelemetryPacket({required this.receivedAtMs, required this.rawData});
}
