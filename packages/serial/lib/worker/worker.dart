import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import '../serial.dart';

// ═══════════════════════════════════════════════════════════════════════════════
// workerMain: Entry Point (Runs in the BACKGROUND Isolate)
// ═══════════════════════════════════════════════════════════════════════════════

/// Entry point executed inside the dedicated background serial isolate.
///
/// Must be a top-level function so [Isolate.spawn] can locate and invoke it.
/// Runs a headless event loop responsible for:
/// 1. Native serial port I/O (via pure FFI libserialport).
/// 2. 1:1 raw binary disk dumping (via [Recorder]).
/// 3. Stream framing and packet parsing (via [PacketParser]).
void workerMain(SendPort mainSendPort) async {
  // ── Handshake Step 1 ─────────────────────────────────────────────────────────
  // Create an inbox for receiving commands from the main UI isolate
  final commandPort = ReceivePort();

  // Send our command SendPort (thread channel) back to the main UI isolate
  mainSendPort.send(commandPort.sendPort);

  // Initialize isolate-local services
  final service = SerialService();
  final parser = PacketParser();
  final recorder = Recorder();

  var status = const SerialWorkerStatus();
  StreamSubscription<Uint8List>? byteSubscription;

  /// Updates local status and notifies the main UI isolate
  void pushStatus(SerialWorkerStatus next) {
    status = next;
    mainSendPort.send(StatusChangedEvent(next));
  }

  /// Subscribes to the serial byte stream and processes chunks concurrently
  void attachByteStream() {
    byteSubscription?.cancel();
    byteSubscription = service.byteStream.listen(
      (chunk) {
        // 1. Exact 1:1 raw binary disk recording (includes noise, preamble, fragments)
        recorder.recordBytes(chunk);

        // 2. Decode valid telemetry frames and forward them to the UI isolate
        for (final packet in parser.feed(chunk)) {
          mainSendPort.send(PacketReceivedEvent(packet));
        }
      },
      onError: (Object e) {
        service.disconnect();
        parser.reset();
        pushStatus(status.copyWith(isConnected: false, connectedPort: null));
        mainSendPort.send(ErrorEvent('Port error: $e'));
      },
      onDone: () {
        parser.reset();
        pushStatus(status.copyWith(isConnected: false, connectedPort: null));
      },
    );
  }

  // Push initial hardware port discovery list upon startup
  mainSendPort.send(PortListEvent(SerialService.availablePorts));

  // ── Command Loop ─────────────────────────────────────────────────────────────
  // Dart's event loop handles this command loop and the serial byte stream
  // concurrently without thread contention or manual mutex locking.
  await for (final message in commandPort) {
    if (message is! SerialCommand) continue;

    switch (message) {
      case ConnectCommand(:final port):
        byteSubscription?.cancel();
        byteSubscription = null;
        service.disconnect();
        parser.reset();

        // Connect using centralized SerialHardwareConfig settings
        final ok = service.connect(port);

        if (ok) {
          pushStatus(status.copyWith(isConnected: true, connectedPort: port));
          attachByteStream();
        } else {
          mainSendPort.send(ErrorEvent('Failed to open $port'));
        }

      case DisconnectCommand():
        byteSubscription?.cancel();
        byteSubscription = null;
        service.disconnect();
        parser.reset();
        pushStatus(status.copyWith(isConnected: false, connectedPort: null));

      case ListPortsCommand():
        mainSendPort.send(PortListEvent(SerialService.availablePorts));

      case SendBytesCommand(:final bytes):
        if (!service.sendBytes(bytes)) {
          mainSendPort.send(ErrorEvent(
            'Not connected — failed to send ${bytes.length} byte(s)',
          ));
        }

      case StartRecordingCommand(:final filePath, :final launch):
        await recorder.start(filePath, launch: launch);
        pushStatus(status.copyWith(isRecording: true, recordingPath: filePath));

      case StopRecordingCommand():
        await recorder.stop();
        pushStatus(status.copyWith(isRecording: false, recordingPath: null));
    }
  }
}
