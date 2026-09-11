import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:serial/serial.dart';

import '../core/app_config.dart';
import '../core/ring_buffer.dart';
import '../core/dead_reckoning.dart';
import './elevation_service.dart';
import './telemetry_provider.dart';

/// Aggregate of everything the dashboard knows about the current flight.
///
/// [history] and [deadReckoningHistory] are *live views* over the store's
/// ring buffers — they always reflect the newest data without any copying,
/// so tiles can iterate them freely on every build.
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
/// Tiles watch [telemetryStoreProvider]; replay code calls [ingest]
/// directly. Live streaming starts automatically via the stream subscription.
final telemetryStoreProvider =
    NotifierProvider<TelemetryStore, TelemetryState>(TelemetryStore.new);

class TelemetryStore extends Notifier<TelemetryState> {
  static const int _historyCapacity = AppConfig.telemetryHistoryCapacity;

  /// Dead reckoning kicks in only after GPS has been silent this long.
  /// Tiles reuse it to decide when the link (as opposed to just the GPS fix)
  /// has gone stale.
  static const int drStaleMs = AppConfig.drStaleMs;

  /// Interval between dead-reckoning points/ticks.
  static const int drUpdateIntervalMs = AppConfig.drUpdateIntervalMs;

  late RingBuffer<TelemetryFrame> _history;
  late RingBuffer<DrPosition> _drHistory;
  final DeadReckoningEstimator _deadReckoning = DeadReckoningEstimator();

  /// Frame time of the last point pushed to the DR history.
  int _lastDrMs = 0;

  /// z=12 tile key ("12/x/y") for the last terrain elevation query.  A new
  /// query is fired only when the rocket moves into a different tile (≈6 km
  /// at 50° lat) — within one tile the cached Future is reused instantly.
  String? _lastElevTileKey;

  /// Ground-side extrapolation timer while the link itself is silent.
  Timer? _drTicker;

  /// Throttle: rebuild the exposed state at most this often (history-heavy
  /// tiles otherwise rebuild on every one of the 10 Hz packets).
  static const int _minNotifyIntervalMs = AppConfig.minNotifyIntervalMs;
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
    // Dead reckoning is a live-only gap filler — replays show the recorded
    // GPS track as-is (no synthetic estimates).
    DrPosition? dr;
    if (!state.replaying) {
      dr = _deadReckoning.update(frame);
      if (dr != null && _shouldPushDr(frame.receivedAtMs)) {
        _drHistory.push(dr);
        _lastDrMs = frame.receivedAtMs;
      }
      _ensureDrTicker();
      // Query terrain elevation whenever the fix moves into a new z=12 tile
      // (≈6 km at 50° lat).  The elevation_service memory-caches per tile, so
      // a cache hit resolves synchronously; misses fall through to the disk
      // cache and then the network.  The DR estimator uses the result as its
      // ground-collision floor via setTerrainFloor(), merging it with the
      // GPS-min heuristic via max() — so a bad terrain value can only raise
      // the clamp, never lower it below a confirmed fix.
      if (frame.gpsHasFix) {
        _maybeQueryTerrain(frame.latitude, frame.longitude);
      }
    }

    if (state.replaying) {
      state = _copyWithCurrent(
        latest: frame,
        packetCount: state.packetCount + 1,
        sourceName: sourceName ?? state.sourceName,
        clearDeadReckoning: true,
      );
    } else {
      state = _copyWithCurrent(
        latest: frame,
        deadReckoning: dr,
        packetCount: state.packetCount + 1,
        sourceName: sourceName ?? state.sourceName,
      );
    }
  }

  /// Bulk-ingests packets with a single state rebuild.
  ///
  /// Replay clocks and seeks push hundreds-to-thousands of packets at once;
  /// ingesting them one by one would notify every watching tile per packet
  /// (26k rebuilds per scrub on a full flight log). Dead reckoning is a
  /// live-only gap filler, so in replay mode it is skipped exactly like in
  /// [ingest]; callers outside replay mode fall back to [ingest] to preserve
  /// the DR + ticker behaviour.
  void ingestPackets(List<TelemetryPacket> packets, {String? sourceName}) {
    if (packets.isEmpty) return;
    if (!state.replaying) {
      for (final packet in packets) {
        ingest(packet, sourceName: sourceName);
      }
      return;
    }
    TelemetryFrame? last;
    var errors = 0;
    for (final packet in packets) {
      final frame = FrameCodec.decode(
        packet.rawData,
        receivedAtMs: packet.receivedAtMs,
      );
      if (frame == null) {
        errors++;
        continue;
      }
      _history.push(frame);
      last = frame;
    }
    state = _copyWithCurrent(
      latest: last ?? state.latest,
      packetCount: state.packetCount + packets.length - errors,
      errorCount: state.errorCount + errors,
      sourceName: sourceName ?? state.sourceName,
      clearDeadReckoning: true,
    );
  }

  /// DR is only computed while GPS is stale: with a fresh fix the fix itself
  /// is the best estimate and the estimator would just duplicate the GPS
  /// track. Once GPS has been silent for over drStaleMs, extrapolate.
  bool _shouldPushDr(int nowMs) {
    final lastFix = _deadReckoning.lastFixAtMs;
    if (lastFix == null || nowMs - lastFix < drStaleMs) return false;
    return nowMs - _lastDrMs >= drUpdateIntervalMs;
  }

  /// Keeps extrapolating dead reckoning at [drUpdateIntervalMs] even when no
  /// packets arrive at all (link loss), using the last known velocity.
  void _ensureDrTicker() {
    if (_drTicker != null) return;
    _drTicker =
        Timer.periodic(const Duration(milliseconds: drUpdateIntervalMs), (_) {
      _extrapolateDr();
    });
  }

  void _extrapolateDr() {
    if (state.replaying || _history.isEmpty) return;
    final latest = _history[0];
    final now = DateTime.now().millisecondsSinceEpoch;
    // Data still flowing — the frame path owns DR updates.
    if (now - latest.receivedAtMs < drStaleMs) return;

    final dr = _deadReckoning.extrapolate(now);
    if (dr == null) return;
    if (dr.atMs - _lastDrMs < drUpdateIntervalMs) return;
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
    _lastElevTileKey = null;
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

  /// Fires a terrain elevation query for [lat]/[lon] when the rocket has
  /// moved into a new z=12 Terrarium tile.  The result is fed back to the DR
  /// estimator asynchronously via [setTerrainFloor]; any failure is silently
  /// swallowed — the estimator falls back to the GPS-min heuristic.
  void _maybeQueryTerrain(double lat, double lon) {
    final key = elevationTileKey(lat, lon);
    if (key == _lastElevTileKey) return; // same tile — cached Future is enough
    _lastElevTileKey = key;
    elevationMsl(lat, lon).then((msl) {
      if (msl != null) _deadReckoning.setTerrainFloor(msl);
    });
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

  /// Rebuilds the state object so tiles watching the provider repaint from
  /// the (already mutated) ring buffers. Always republishes the estimator's
  /// current position: during a link loss the 1 Hz extrapolator advances it
  /// with no new frames, and without this the exposed DR would freeze at the
  /// last fix (indistinguishable from GPS).
  void _rebuildState() {
    state = _copyWithCurrent(
      latest: _history.isEmpty ? null : _history[0],
      deadReckoning: _deadReckoning.position,
    );
  }

  /// A new state sharing the live buffers, with the given overrides.
  TelemetryState _copyWithCurrent({
    TelemetryFrame? latest,
    DrPosition? deadReckoning,
    bool clearDeadReckoning = false,
    int? packetCount,
    int? errorCount,
    String? sourceName,
    bool? replaying,
  }) {
    return TelemetryState(
      history: _history,
      deadReckoningHistory: _drHistory,
      latest: latest ?? state.latest,
      deadReckoning:
          clearDeadReckoning ? null : (deadReckoning ?? state.deadReckoning),
      packetCount: packetCount ?? state.packetCount,
      errorCount: errorCount ?? state.errorCount,
      sourceName: sourceName ?? state.sourceName,
      replaying: replaying ?? state.replaying,
    );
  }
}
