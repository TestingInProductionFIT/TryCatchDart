import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:serial/serial.dart';

import './launch_site_store.dart';
import '../core/app_config.dart';
import '../core/channel_health.dart';
import '../core/flight_events.dart';
import './telemetry_store.dart';

/// Maps a recording header's launch reference to a display site, or `null`
/// when the header is missing or carries no site.
LaunchSite? launchSiteFromHeader(RecordingHeader? header) {
  final launch = header?.launchRef;
  if (launch == null) return null;
  return LaunchSite(
    name: launch.name,
    latitude: launch.latitude,
    longitude: launch.longitude,
    altitudeMsl: launch.mslM,
  );
}

/// Launch site the visuals (map flag, 3D origin, distances) should anchor
/// to: the replay file's own site while a replay is active (which may be
/// `null` — then no flag is shown rather than a fallback), else the
/// selected site.
final effectiveLaunchSiteProvider = Provider<LaunchSite?>((ref) {
  final replay = ref.watch(replayProvider);
  if (replay.isActive) return replay.launchSite;
  return ref.watch(currentLaunchSiteProvider);
});

/// Replay playback state.
class ReplayState {
  /// Recording currently loaded, or `null` when idle.
  final String? filePath;

  final bool playing;

  /// Playback speed multiplier (0.5, 1, 4, 20).
  final double speed;

  /// Replay clock position relative to recording start (ms of flight time).
  final int positionMs;

  /// Total flight time in the recording (ms), `null` while loading.
  final int? durationMs;

  /// True while a recording is being decoded (play() in flight).
  final bool isLoading;

  /// Set when the recording could not be decoded (unknown format).
  final String? errorMsg;

  /// Every decodable frame of the recording, decoded once up front. Lets
  /// tiles pre-compute whole-flight bounds instead of rescaling while the
  /// replay progresses. Empty outside a replay.
  final List<TelemetryFrame> frames;

  /// Launch site read from the recording header (`null` when the header
  /// carries none). Visuals anchor to this while the replay is active.
  final LaunchSite? launchSite;

  /// Whole-flight channel profile (ours/unknown bytes per 500 ms bin),
  /// rebuilt from the recording's raw chunks so the channel-health monitor
  /// shows the same picture the live view did. Empty outside a replay.
  final List<ChannelBin> channelProfile;

  /// Display-only smoothing for the 3D views (smoothed trail + stabilized
  /// rotation). The recording bytes and charts are always raw; this only
  /// affects how the 3D tiles paint. Defaults off so replays show the
  /// unfiltered sensor picture; toggle it on to resemble the legacy web
  /// visualizer (which averaged the track).
  final bool smoothingEnabled;

  const ReplayState({
    this.filePath,
    this.playing = false,
    this.speed = 1,
    this.positionMs = 0,
    this.durationMs,
    this.isLoading = false,
    this.errorMsg,
    this.frames = const [],
    this.launchSite,
    this.channelProfile = const [],
    this.smoothingEnabled = false,
  });

  bool get isActive => filePath != null;

  ReplayState copyWith({
    String? filePath,
    bool? playing,
    double? speed,
    int? positionMs,
    int? durationMs,
    bool? isLoading,
    String? errorMsg,
    List<TelemetryFrame>? frames,
    LaunchSite? launchSite,
    List<ChannelBin>? channelProfile,
    bool? smoothingEnabled,
  }) => ReplayState(
    filePath: filePath ?? this.filePath,
    playing: playing ?? this.playing,
    speed: speed ?? this.speed,
    positionMs: positionMs ?? this.positionMs,
    durationMs: durationMs ?? this.durationMs,
    isLoading: isLoading ?? this.isLoading,
    errorMsg: errorMsg ?? this.errorMsg,
    frames: frames ?? this.frames,
    launchSite: launchSite ?? this.launchSite,
    channelProfile: channelProfile ?? this.channelProfile,
    smoothingEnabled: smoothingEnabled ?? this.smoothingEnabled,
  );
}

/// Plays a recorded binary telemetry file back through [telemetryStoreProvider]
/// so the whole dashboard works identically on recorded flights.
///
/// The recording's own timestamps drive the clock: a 50 ms ticker ingests all
/// packets whose original arrival time falls under a virtual clock advancing
/// at [ReplayState.speed]× real time.
final replayProvider = NotifierProvider<ReplayController, ReplayState>(
  ReplayController.new,
);

/// Flight milestones (launch / apogee / parachute / touchdown) detected from
/// the loaded replay's FSM transitions, in frame order.
///
/// Derived from the pre-decoded frames list identity, so it computes once per
/// loaded recording — not on every playhead tick. Empty outside a replay or
/// when the flight never made the nominal transitions.
final replayFlightEventsProvider = Provider<List<FlightEvent>>((ref) {
  final frames = ref.watch(replayProvider.select((s) => s.frames));
  return detectFlightEvents(frames);
});

class ReplayController extends Notifier<ReplayState> {
  /// Speed presets offered in the UI.
  static const List<double> speeds = AppConfig.replaySpeeds;

  List<TelemetryPacket> _packets = const [];
  int _index = 0;
  Timer? _ticker;
  int _lastTickMs = 0;

  /// Monotonic load generation: each play()/stop() bumps it, and a pending
  /// play() abandons its result when it notices a newer generation. This
  /// closes the stop-during-loading race — the UI disables the close action
  /// while isLoading, but a programmatic stop (or a second play) must not
  /// be resurrected by the stale decode finishing late.
  int _loadGeneration = 0;

  @override
  ReplayState build() => const ReplayState();

  TelemetryStore get _store => ref.read(telemetryStoreProvider.notifier);

  /// Loads [path], decodes every packet up front and starts playback at 1×.
  Future<void> play(String path) async {
    final initialSmoothing = state.smoothingEnabled;
    final generation = ++_loadGeneration;
    _ticker?.cancel();
    _ticker = null;
    _packets = const [];
    _index = 0;
    _store.setReplaying(false);
    // Publish a loading state immediately so the UI can show a spinner
    // while the (potentially large) file decodes.
    state = ReplayState(
      filePath: path,
      isLoading: true,
      smoothingEnabled: initialSmoothing,
    );

    final packets = await _decode(path);
    if (generation != _loadGeneration) return;
    if (packets.isEmpty) {
      state = ReplayState(
        filePath: path,
        durationMs: 0,
        errorMsg: 'Unsupported recording — expected a recording with a header.',
        // Keep any smoothing toggle made mid-load instead of the entry value.
        smoothingEnabled: state.smoothingEnabled,
      );
      return;
    }

    _packets = packets;
    _index = 0;

    // Pre-decode the whole flight so tiles can fix their axes up front.
    final frames = <TelemetryFrame>[];
    for (final packet in packets) {
      final frame = FrameCodec.decode(
        packet.rawData,
        receivedAtMs: packet.receivedAtMs,
      );
      if (frame != null) frames.add(frame);
    }

    _store.setReplaying(true);
    final site = launchSiteFromHeader(await tryReadRecordingHeader(path));
    if (generation != _loadGeneration) {
      _store.setReplaying(false);
      return;
    }
    if (site == null) {
      _store.setReplaying(false);
      state = ReplayState(
        filePath: path,
        durationMs: 0,
        errorMsg:
            'Unsupported recording — expected a launch site in the header.',
        smoothingEnabled: state.smoothingEnabled,
      );
      return;
    }
    final channelProfile = buildChannelProfile(await readRecordingChunks(path));
    if (generation != _loadGeneration) {
      _store.setReplaying(false);
      return;
    }
    state = ReplayState(
      filePath: path,
      playing: true,
      speed: 1,
      positionMs: 0,
      durationMs: packets.last.receivedAtMs - packets.first.receivedAtMs,
      frames: frames,
      launchSite: site,
      channelProfile: channelProfile,
      smoothingEnabled: state.smoothingEnabled,
    );

    _lastTickMs = DateTime.now().millisecondsSinceEpoch;
    _ticker = Timer.periodic(const Duration(milliseconds: 50), (_) => _tick());
  }

  /// Parses the recording at [path]. Files without a valid header yield
  /// nothing.
  Future<List<TelemetryPacket>> _decode(String path) async {
    final packets = await FileParser().parseFile(path).toList();
    final decodable = packets.any(
      (p) => FrameCodec.decode(p.rawData, receivedAtMs: 0) != null,
    );
    return decodable ? packets : const [];
  }

  /// Advances the virtual clock and ingests everything that is due.
  void _tick() {
    if (_packets.isEmpty || _index >= _packets.length) {
      pause();
      return;
    }

    final now = DateTime.now().millisecondsSinceEpoch;
    final realDt = now - _lastTickMs;
    _lastTickMs = now;

    final speed = state.speed;
    final t0 = _packets.first.receivedAtMs;
    final clock = state.positionMs + (realDt * speed).round();

    // Batch the due packets into one store rebuild — per-packet ingestion
    // notifies every watching tile.
    final due = <TelemetryPacket>[];
    while (_index < _packets.length) {
      final packet = _packets[_index];
      final rel = packet.receivedAtMs - t0;
      if (rel > clock) break;
      due.add(packet);
      _index++;
    }

    if (due.isNotEmpty) _store.ingestPackets(due, sourceName: _fileName());
    state = state.copyWith(positionMs: clock);

    if (_index >= _packets.length) pause();
  }

  void pause() {
    _ticker?.cancel();
    _ticker = null;
    if (state.playing) {
      state = state.copyWith(playing: false);
    }
  }

  void resume() {
    if (!state.isActive || state.isLoading) return;
    if (_index >= _packets.length) {
      // Restart from the beginning when replaying a finished recording.
      seek(0);
    }
    // Idempotent: a stray live ticker is replaced, a dead one while
    // `playing` is healed — resume always converges on ticking playback.
    _ticker?.cancel();
    _lastTickMs = DateTime.now().millisecondsSinceEpoch;
    _ticker = Timer.periodic(
      const Duration(milliseconds: AppConfig.replayTickMs),
      (_) => _tick(),
    );
    if (!state.playing) {
      state = state.copyWith(playing: true);
    }
  }

  /// Single entry point for the play/pause button. Decides by the live timer
  /// rather than the last-published flag alone, so a stale build (or a timer
  /// lost to an exception) can never strand the button: one tap always flips
  /// the actual playback state.
  void toggle() {
    if (state.isLoading) return;
    if ((_ticker?.isActive ?? false) && state.playing) {
      pause();
    } else {
      resume();
    }
  }

  void setSpeed(double speed) {
    if (state.isLoading) return;
    state = state.copyWith(speed: speed);
  }

  /// Current ingestion cursor (packets already in the store). Exposed for
  /// tests pinning the incremental-seek behaviour.
  int get debugIndex => _index;

  /// Toggles the replay-only 3D display smoothing (trail + rotation).
  void setSmoothing(bool enabled) =>
      state = state.copyWith(smoothingEnabled: enabled);

  /// Jumps to [positionMs].
  ///
  /// Forward jumps ingest only the delta (the store already holds everything
  /// before [_index]); backward jumps reset and replay from the start so the
  /// store's history stays consistent. The target is found by binary search
  /// and ingestion is a single bulk rebuild — scrubbing a 26k-packet flight
  /// no longer replays per-packet state churn from zero on every slider tick.
  void seek(int positionMs) {
    if (state.isLoading || _packets.isEmpty) return;

    final t0 = _packets.first.receivedAtMs;
    var lo = 0;
    var hi = _packets.length;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (_packets[mid].receivedAtMs - t0 > positionMs) {
        hi = mid;
      } else {
        lo = mid + 1;
      }
    }
    final index = lo;

    if (index > _index) {
      if (_index == 0) _store.reset(sourceName: _fileName());
      _store.ingestPackets(
        _packets.sublist(_index, index),
        sourceName: _fileName(),
      );
    } else if (index < _index) {
      _store.reset(sourceName: _fileName());
      _store.ingestPackets(_packets.sublist(0, index), sourceName: _fileName());
    }

    _index = index;
    state = state.copyWith(positionMs: positionMs);
  }

  /// Stops playback and returns the store to live mode.
  void stop() {
    // Invalidate any in-flight play() so its late async completion is
    // dropped instead of resurrecting a replay the user just closed.
    _loadGeneration++;
    _ticker?.cancel();
    _ticker = null;
    _packets = const [];
    _index = 0;
    _store.setReplaying(false);
    state = const ReplayState();
  }

  String _fileName() =>
      state.filePath?.split(Platform.pathSeparator).last ?? 'replay';
}
