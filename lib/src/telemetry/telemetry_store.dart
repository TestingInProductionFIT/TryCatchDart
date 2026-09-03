import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:serial/serial.dart';

import '../collections/ring_buffer.dart';
import '../estimation/dead_reckoning.dart';
import 'telemetry_provider.dart';

/// Aggregate of everything the dashboard knows about the current flight.
///
/// [history] and [deadReckoningHistory] are *live views* over the store's
/// ring buffers — they always reflect the newest data without any copying,
/// so widgets can iterate them freely on every build.
class TelemetryState {
  /// Most recently decoded frame, or `null` before the first packet.
  final TelemetryFrame? latest;

  /// Latest dead-reckoned position, or `null` before the first GPS fix.
  final DrPosition? deadReckoning;

  /// Dead-reckoning history (chronological, bounded).
  final RingBuffer<DrPosition> deadReckoningHistory;

  /// Capped flight history (chronological, bounded).
  final RingBuffer<TelemetryFrame> history;

  /// Total packets ingested this session (including dropped/corrupt).
  final int packetCount;

  /// Packets whose CRC failed or that could not be decoded.
  final int errorCount;

  /// Human-readable data source ('COM3', 'MOCK', recording file name...).
  final String sourceName;

  /// Whether we are currently replaying a recording.
  final bool replaying;

  TelemetryState({
    required this.history,
    required this.deadReckoningHistory,
    this.latest,
    this.deadReckoning,
    this.packetCount = 0,
    this.errorCount = 0,
    this.sourceName = '',
    this.replaying = false,
  });

  /// Maximum barometric altitude reached so far (m AGL).
  double get maxAltitude {
    var m = latest?.baroAltitude ?? 0.0;
    for (final f in history) {
      if (f.baroAltitude > m) m = f.baroAltitude;
    }
    return m;
  }

  /// Maximum total speed reached so far (m/s).
  double get maxSpeed {
    var m = 0.0;
    for (final f in history) {
      if (f.speedTotal > m) m = f.speedTotal;
    }
    return m;
  }

  /// Maximum total acceleration reached so far (m/s²).
  double get maxAccel {
    var m = 0.0;
    for (final f in history) {
      if (f.accelTotal > m) m = f.accelTotal;
    }
    return m;
  }

  /// `receivedAtMs` of the first frame in history, or `null` when empty.
  int? get firstPacketMs =>
      history.isEmpty ? null : history.getChronological(0).receivedAtMs;

  /// Elapsed session time (ms) since the first packet.
  int? get elapsedMs => firstPacketMs == null || latest == null
      ? null
      : latest!.receivedAtMs - firstPacketMs!;
}

/// Single ingestion point for telemetry: subscribes to the serial worker's
/// packet stream, decodes frames, tracks dead reckoning and keeps bounded
/// history + derived stats.
///
/// Widgets watch [telemetryStoreProvider]; replay code calls [ingest]
/// directly. Live streaming starts automatically via the stream subscription.
final telemetryStoreProvider =
    NotifierProvider<TelemetryStore, TelemetryState>(TelemetryStore.new);

class TelemetryStore extends Notifier<TelemetryState> {
  static const int _historyCapacity = 9000; // ~15 min @ 10 Hz

  /// Dead reckoning kicks in only after GPS has been silent this long, and
  /// then updates at most once per second.
  static const int _drStaleMs = 1000;

  late RingBuffer<TelemetryFrame> _history;
  late RingBuffer<DrPosition> _drHistory;
  final DeadReckoningEstimator _deadReckoning = DeadReckoningEstimator();

  /// Frame time of the last point pushed to the DR history (1 Hz spacing).
  int _lastDrMs = 0;

  /// 1 Hz ground-side extrapolation while the link itself is silent.
  Timer? _drTicker;

  /// Throttle: rebuild the exposed state at most this often (history-heavy
  /// widgets otherwise rebuild on every one of the 10 Hz packets).
  static const int _minNotifyIntervalMs = 80;
  int _lastNotifyMs = 0;
  bool _pendingNotify = false;

  @override
  TelemetryState build() {
    _history = RingBuffer(_historyCapacity);
    _drHistory = RingBuffer(_historyCapacity);

    // Auto-ingest the live serial stream for the lifetime of the provider.
    ref.listen(telemetryStreamProvider, (previous, next) {
      // During a replay the live stream must not mix into the recording.
      if (state.replaying) return;
      next.whenData((packet) => ingest(packet, sourceName: _liveSourceName()));
    });

    // Clear the flight when the connection drops or the port changes.
    ref.listen(serialStatusProvider, (previous, next) {
      next.whenData((status) {
        final name = status.connectedPort ?? '';
        if (state.sourceName.isNotEmpty &&
            name.isNotEmpty &&
            name != state.sourceName &&
            !state.replaying) {
          reset(sourceName: name);
        }
      });
    });

    return TelemetryState(
      history: _history,
      deadReckoningHistory: _drHistory,
    );
  }

  String _liveSourceName() {
    final status = ref.read(serialStatusProvider).value;
    return status?.connectedPort ?? 'unknown';
  }

  /// Ingests a raw packet (live or replay). Decoding failures count as errors.
  void ingest(TelemetryPacket packet, {String? sourceName}) {
    final frame =
        FrameCodec.decode(packet.rawData, receivedAtMs: packet.receivedAtMs);
    if (frame == null) {
      state = _copyWithCurrent(errorCount: state.errorCount + 1);
      return;
    }

    _history.push(frame);
    final dr = _deadReckoning.update(frame);
    if (dr != null && _shouldPushDr(frame.receivedAtMs)) {
      _drHistory.push(dr);
      _lastDrMs = frame.receivedAtMs;
    }
    _ensureDrTicker();

    state = _copyWithCurrent(
      latest: frame,
      deadReckoning: dr,
      packetCount: state.packetCount + 1,
      sourceName: sourceName ?? state.sourceName,
    );
  }

  /// DR is only computed while GPS is stale: with a fresh fix the fix itself
  /// is the best estimate and the estimator would just duplicate the GPS
  /// track. Once GPS has been silent for over a second, extrapolate — at
  /// most one point per second of frame time.
  bool _shouldPushDr(int nowMs) {
    final lastFix = _deadReckoning.lastFixAtMs;
    if (lastFix == null || nowMs - lastFix < _drStaleMs) return false;
    return nowMs - _lastDrMs >= _drStaleMs;
  }

  /// Keeps extrapolating dead reckoning once per second even when no packets
  /// arrive at all (link loss), using the last known velocity.
  void _ensureDrTicker() {
    if (_drTicker != null) return;
    _drTicker = Timer.periodic(const Duration(seconds: 1), (_) {
      _extrapolateDr();
    });
  }

  void _extrapolateDr() {
    if (state.replaying || _history.isEmpty) return;
    final latest = _history[0];
    final now = DateTime.now().millisecondsSinceEpoch;
    // Data still flowing — the frame path owns DR updates.
    if (now - latest.receivedAtMs < _drStaleMs) return;

    final dr = _deadReckoning.extrapolate(now);
    if (dr == null) return;
    if (dr.atMs - _lastDrMs < _drStaleMs) return;
    _drHistory.push(dr);
    _lastDrMs = dr.atMs;
    _rebuildState();
  }

  /// Clears the flight (new connection, new replay...).
  void reset({String? sourceName}) {
    _history.clear();
    _drHistory.clear();
    _deadReckoning.reset();
    _lastDrMs = 0;
    _drTicker?.cancel();
    _drTicker = null;
    _lastNotifyMs = 0;
    state = TelemetryState(
      history: _history,
      deadReckoningHistory: _drHistory,
      sourceName: sourceName ?? '',
      replaying: state.replaying,
    );
  }

  /// Marks whether the current data is a replay.
  void setReplaying(bool replaying) {
    if (state.replaying == replaying) return;
    reset(sourceName: replaying ? state.sourceName : '');
    state = _copyWithCurrent(replaying: replaying);
  }

  /// Schedules a throttled state rebuild for high-frequency update paths.
  ///
  /// Used by replay clocks that push hundreds of frames per second: state is
  /// exposed to the UI at most every [_minNotifyIntervalMs] but the internal
  /// history is always up to date.
  void notifyThrottled() {
    final now = DateTime.now().millisecondsSinceEpoch;
    if (now - _lastNotifyMs >= _minNotifyIntervalMs) {
      _lastNotifyMs = now;
      _pendingNotify = false;
      _rebuildState();
      return;
    }
    if (_pendingNotify) return;
    _pendingNotify = true;
    Future.delayed(Duration(milliseconds: _minNotifyIntervalMs), () {
      if (!_pendingNotify) return;
      _pendingNotify = false;
      _lastNotifyMs = DateTime.now().millisecondsSinceEpoch;
      _rebuildState();
    });
  }

  /// Rebuilds the state object so widgets watching the provider repaint from
  /// the (already mutated) ring buffers.
  void _rebuildState() {
    state = _copyWithCurrent(latest: _history.isEmpty ? null : _history[0]);
  }

  /// A new state sharing the live buffers, with the given overrides.
  TelemetryState _copyWithCurrent({
    TelemetryFrame? latest,
    DrPosition? deadReckoning,
    int? packetCount,
    int? errorCount,
    String? sourceName,
    bool? replaying,
  }) {
    return TelemetryState(
      history: _history,
      deadReckoningHistory: _drHistory,
      latest: latest ?? state.latest,
      deadReckoning: deadReckoning ?? state.deadReckoning,
      packetCount: packetCount ?? state.packetCount,
      errorCount: errorCount ?? state.errorCount,
      sourceName: sourceName ?? state.sourceName,
      replaying: replaying ?? state.replaying,
    );
  }
}
