import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:serial/serial.dart';

import '../../settings/launch_site_store.dart';

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
/// In widgets: `ref.watch(telemetryStreamProvider)`
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

/// Resolved path to the user's `Documents/TryCatch/recordings/` directory.
final recordingsDirectoryProvider = FutureProvider<String>((ref) async {
  return SerialConfigNotifier.getRecordingsDirectory();
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
  ///
  /// The currently selected launch site (if any) is stamped into the
  /// recording file header; otherwise the recorder falls back to the first
  /// GPS fix in the stream.
  Future<void> startRecording() async {
    final now = DateTime.now();
    final timestamp =
        '${now.year}-${_twoDigits(now.month)}-${_twoDigits(now.day)}_'
        '${_twoDigits(now.hour)}-${_twoDigits(now.minute)}-${_twoDigits(now.second)}';

    final dirPath = await getRecordingsDirectory();
    final filePath = '$dirPath${Platform.pathSeparator}telemetry_$timestamp.bin';

    final site = ref.read(currentLaunchSiteProvider);
    ref.read(serialWorkerProvider).send(StartRecordingCommand(
          filePath: filePath,
          launch: site == null
              ? null
              : LaunchRef(
                  latitude: site.latitude,
                  longitude: site.longitude,
                  mslM: site.altitudeMsl,
                  name: site.name,
                ),
        ));
  }

  /// Stops the active recording session.
  void stopRecording() {
    ref.read(serialWorkerProvider).send(const StopRecordingCommand());
  }

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
  Future<void> openRecordingsFolder() async {
    final path = await getRecordingsDirectory();
    final dir = Directory(path);
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }

    if (Platform.isWindows) {
      await Process.run('explorer.exe', [dir.absolute.path]);
    } else if (Platform.isMacOS) {
      await Process.run('open', [dir.absolute.path]);
    } else if (Platform.isLinux) {
      await Process.run('xdg-open', [dir.absolute.path]);
    }
  }

  /// Resolves the user's `Documents/TryCatch/recordings` directory cross-platform.
  static Future<String> getRecordingsDirectory() async {
    try {
      final docsDir = await getApplicationDocumentsDirectory();
      final dir = Directory(
        '${docsDir.path}${Platform.pathSeparator}TryCatch${Platform.pathSeparator}recordings',
      );
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }
      return dir.path;
    } catch (_) {
      // Fallback for standalone/test environments
      final fallback = Directory(
        '${Directory.current.path}${Platform.pathSeparator}recordings',
      );
      if (!await fallback.exists()) {
        await fallback.create(recursive: true);
      }
      return fallback.path;
    }
  }

  static String _twoDigits(int n) => n >= 10 ? '$n' : '0$n';
}
