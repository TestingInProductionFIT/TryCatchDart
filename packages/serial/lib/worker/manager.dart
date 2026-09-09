import 'dart:async';
import 'dart:isolate';

import '../serial.dart';
import 'worker.dart';

// ═══════════════════════════════════════════════════════════════════════════════
// SerialWorker: Client Handle (Runs in the MAIN / UI Isolate)
// ═══════════════════════════════════════════════════════════════════════════════

/// A high-level controller and client handle that lives in the main UI isolate.
///
/// Analogous to a Web Worker instance in JavaScript or a thread manager in C:
/// - Sends typed [SerialCommand]s to the background worker isolate.
/// - Exposes categorized broadcast [Stream]s for UI widgets to consume.
///
/// In Dart, isolates do NOT share memory heaps. All communication is done via
/// message passing over [SendPort] and [ReceivePort].
class SerialWorker {
  final Isolate _isolate;

  /// The communication pipe endpoint (SendPort) to send commands to the background worker.
  /// Initialized during the two-way handshake upon isolate startup.
  SendPort? _commandPort;

  // Broadcast stream controllers: allow multiple UI widgets to listen simultaneously
  final _statusController = StreamController<SerialWorkerStatus>.broadcast();
  final _packetController = StreamController<TelemetryPacket>.broadcast();
  final _portsController = StreamController<List<String>>.broadcast();
  final _linkStatsController = StreamController<LinkStats>.broadcast();

  // Cached state snapshots: allow UI widgets to perform immediate synchronous reads
  // without waiting for the next stream event (avoids UI loading flashes).
  SerialWorkerStatus _status = const SerialWorkerStatus();
  List<String> _ports = const [];
  LinkStats _linkStats = LinkStats.empty;

  /// Current synchronous snapshot of the worker's operational status.
  SerialWorkerStatus get currentStatus => _status;

  /// Current synchronous snapshot of available COM / serial ports.
  List<String> get currentPorts => _ports;

  /// Stream of connection and recording status transitions.
  Stream<SerialWorkerStatus> get statusStream => _statusController.stream;

  /// Stream of successfully framed and parsed [TelemetryPacket]s.
  Stream<TelemetryPacket> get packetStream => _packetController.stream;

  /// Stream of scanned serial/COM port list updates.
  Stream<List<String>> get portsStream => _portsController.stream;

  /// Latest cumulative link-health snapshot from the worker.
  LinkStats get currentLinkStats => _linkStats;

  /// Stream of cumulative [LinkStats] snapshots (~2 Hz while connected).
  Stream<LinkStats> get linkStatsStream => _linkStatsController.stream;

  SerialWorker._(this._isolate, ReceivePort receivePort) {
    // Listen for incoming events emitted by the background worker isolate
    receivePort.listen(_handleMessage);
  }

  /// Handles incoming messages received from the background worker isolate.
  void _handleMessage(dynamic message) {
    // ── Handshake Step 2 ───────────────────────────────────────────────────────
    // The very first message sent by the worker is its own command SendPort
    // (a thread communication channel, NOT a hardware COM port).
    if (message is SendPort) {
      _commandPort = message;
      // Immediately request an initial scan of available hardware ports
      _commandPort!.send(const ListPortsCommand());
      return;
    }

    if (message is! SerialEvent) return;

    // ── Event Dispatching ─────────────────────────────────────────────────────
    // Route domain events to their respective broadcast stream controllers
    switch (message) {
      case PacketReceivedEvent(:final packet):
        _packetController.add(packet);

      case StatusChangedEvent(:final status):
        _status = status;
        _statusController.add(status);

      case PortListEvent(:final ports):
        // Note: PortListEvent contains hardware COM port names (e.g. 'COM3', 'MOCK')
        _ports = ports;
        _portsController.add(ports);

      case LinkStatsEvent(:final stats):
        _linkStats = stats;
        _linkStatsController.add(stats);

      case ErrorEvent(:final message):
        // ignore: avoid_print
        print('[SerialWorker Error] $message');
    }
  }

  /// Spawns the dedicated serial background isolate.
  ///
  /// This creates a new OS thread running an isolated Dart heap.
  /// Call this once during app initialization in [main] before [runApp].
  static Future<SerialWorker> spawn() async {
    // Create an inbox (ReceivePort) for the main isolate
    final receivePort = ReceivePort();

    // Spawn the background thread and pass our SendPort so it can talk back
    final isolate = await Isolate.spawn(
      workerMain,
      receivePort.sendPort,
      debugName: 'SerialWorker',
    );

    return SerialWorker._(isolate, receivePort);
  }

  /// Posts a [SerialCommand] to the background worker isolate.
  ///
  /// The command object is serialized/copied across the isolate boundary.
  void send(SerialCommand command) {
    assert(
      _commandPort != null,
      'SerialWorker.send() called before the isolate finished its startup handshake.',
    );
    _commandPort?.send(command);
  }

  /// Terminates the background isolate and releases all stream controllers.
  void dispose() {
    _statusController.close();
    _packetController.close();
    _portsController.close();
    _linkStatsController.close();
    _isolate.kill(priority: Isolate.beforeNextEvent);
  }
}
