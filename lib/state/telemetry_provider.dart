import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:serial/serial.dart';

import './recording_provider.dart';
export './recording_provider.dart';

// ─── Core worker provider ──────────────────────────────────────────────────────

/// Holds the live [SerialWorker] handle.
///
/// Overridden in [main] with the instance spawned before [runApp].
final serialWorkerProvider = Provider<SerialWorker>((ref) {
  throw UnimplementedError(
    'serialWorkerProvider must be overridden in main() via ProviderScope.overrides.',
  );
});

// ─── Event-derived stream providers ───────────────────────────────────────────

/// Stream of parsed [TelemetryPacket]s from the serial worker.
///
/// In tiles: `ref.watch(telemetryStreamProvider)`
///   → `AsyncValue<TelemetryPacket>` (loading / data / error)
final telemetryStreamProvider = StreamProvider<TelemetryPacket>((ref) {
  return ref.watch(serialWorkerProvider).packetStream;
});

/// Current serial worker status (connected, recording, active port, etc.).
///
/// Yields [SerialWorkerStatus] immediately with the latest cached value, then
/// streams every subsequent change.
final serialStatusProvider = StreamProvider<SerialWorkerStatus>((ref) async* {
  final worker = ref.watch(serialWorkerProvider);
  yield worker.currentStatus;
  yield* worker.statusStream;
});

/// Stream of cumulative link-health snapshots from the serial worker.
///
/// Emitted ~2 Hz while connected (plus throttled updates on traffic bursts).
/// The channel-health monitor derives bytes/s rates from counter deltas.
final linkStatsStreamProvider = StreamProvider<LinkStats>((ref) {
  final worker = ref.watch(serialWorkerProvider);
  return worker.linkStatsStream;
});

/// Most recently reported list of available serial ports.
final availablePortsProvider = StreamProvider<List<String>>((ref) async* {
  final worker = ref.watch(serialWorkerProvider);
  yield worker.currentPorts;
  yield* worker.portsStream;
});


// ─── UI-side connection config ─────────────────────────────────────────────────

/// Stores the selected port before the user clicks Connect.
class SerialConfig {
  final String? selectedPort;

  const SerialConfig({this.selectedPort});

  static const _absent = Object();

  SerialConfig copyWith({Object? selectedPort = _absent}) {
    return SerialConfig(
      selectedPort: identical(selectedPort, _absent)
          ? this.selectedPort
          : selectedPort as String?,
    );
  }
}

final serialConfigProvider =
    NotifierProvider<SerialConfigNotifier, SerialConfig>(
  SerialConfigNotifier.new,
);

/// Manages the pending serial config and dispatches commands to the worker.
class SerialConfigNotifier extends Notifier<SerialConfig> {
  @override
  SerialConfig build() => const SerialConfig();

  void setPort(String? port) => state = state.copyWith(selectedPort: port);

  /// Dispatches a [ConnectCommand] to the serial worker with the configured hardware settings.
  void connect() {
    final cfg = state;
    if (cfg.selectedPort == null) return;
    ref.read(serialWorkerProvider).send(ConnectCommand(cfg.selectedPort!));
  }

  /// Dispatches a [DisconnectCommand] to the serial worker.
  void disconnect() =>
      ref.read(serialWorkerProvider).send(const DisconnectCommand());

  /// Asks the worker to re-scan and push an updated port list.
  void refreshPorts() =>
      ref.read(serialWorkerProvider).send(const ListPortsCommand());

  /// Starts a recording session with an auto-generated timestamp file in the documents recordings folder.
  Future<void> startRecording() => RecordingService.startRecording(ref);

  /// Stops the active recording session.
  void stopRecording() => RecordingService.stopRecording(ref);

  /// Transmits raw [bytes] to the rocket over the active connection.
  ///
  /// Used by the data-driven control panel; returns whether the command was
  /// dispatched at all (connection state is checked by the worker).
  bool sendBytes(List<int> bytes) {
    final status = ref.read(serialStatusProvider).value;
    if (status?.isConnected != true) return false;
    ref
        .read(serialWorkerProvider)
        .send(SendBytesCommand(Uint8List.fromList(bytes)));
    return true;
  }

  /// Opens the recordings folder in the desktop OS file explorer.
  Future<void> openRecordingsFolder() => RecordingService.openRecordingsFolder();

  /// Resolves the user's `Documents/TryCatch/recordings` directory cross-platform.
  static Future<String> getRecordingsDirectory() =>
      RecordingService.getRecordingsDirectory();
}
