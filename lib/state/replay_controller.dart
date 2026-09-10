import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:serial/serial.dart';

import './launch_site_store.dart';
import '../core/channel_health.dart';
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

  /// Playback speed multiplier (1, 4, 20; 999 ≈ as fast as possible).
  final double speed;

  /// Replay clock position relative to recording start (ms of flight time).
  final int positionMs;

  /// Total flight time in the recording (ms), `null` while loading.
  final int? durationMs;

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

  const ReplayState({
    this.filePath,
    this.playing = false,
    this.speed = 1,
    this.positionMs = 0,
    this.durationMs,
    this.errorMsg,
    this.frames = const [],
    this.launchSite,
    this.channelProfile = const [],
  });

  bool get isActive => filePath != null;

  ReplayState copyWith({
    String? filePath,
    bool? playing,
    double? speed,
    int? positionMs,
    int? durationMs,
    String? errorMsg,
    List<TelemetryFrame>? frames,
    LaunchSite? launchSite,
    List<ChannelBin>? channelProfile,
  }) =>
      ReplayState(
        filePath: filePath ?? this.filePath,
        playing: playing ?? this.playing,
        speed: speed ?? this.speed,
        positionMs: positionMs ?? this.positionMs,
        durationMs: durationMs ?? this.durationMs,
        errorMsg: errorMsg ?? this.errorMsg,
        frames: frames ?? this.frames,
        launchSite: launchSite ?? this.launchSite,
        channelProfile: channelProfile ?? this.channelProfile,
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

class ReplayController extends Notifier<ReplayState> {
  /// Speed presets offered in the UI.
  static const List<double> speeds = [1, 4, 20, 999];

  List<TelemetryPacket> _packets = const [];
  int _index = 0;
  Timer? _ticker;
  int _lastTickMs = 0;

  @override
  ReplayState build() => const ReplayState();

  TelemetryStore get _store => ref.read(telemetryStoreProvider.notifier);

  /// Loads [path], decodes every packet up front and starts playback at 1×.
  Future<void> play(String path) async {
    stop();

    final packets = await _decode(path);
    if (packets.isEmpty) {
      state = ReplayState(
        filePath: path,
        durationMs: 0,
        errorMsg:
            'Unsupported recording — expected a recording with a header.',
      );
      return;
    }

    _packets = packets;
    _index = 0;

    // Pre-decode the whole flight so tiles can fix their axes up front.
    final frames = <TelemetryFrame>[];
    for (final packet in packets) {
      final frame =
          FrameCodec.decode(packet.rawData, receivedAtMs: packet.receivedAtMs);
      if (frame != null) frames.add(frame);
    }

    _store.setReplaying(true);
    final site =
        launchSiteFromHeader(await tryReadRecordingHeader(path));
    if (site == null) {
      _store.setReplaying(false);
      state = ReplayState(
        filePath: path,
        durationMs: 0,
        errorMsg:
            'Unsupported recording — expected a launch site in the header.',
      );
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
      channelProfile:
          buildChannelProfile(await readRecordingChunks(path)),
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
    var clock = state.positionMs + (realDt * speed).round();
    if (speed >= 999) clock = _packets.last.receivedAtMs - t0;

    var ingested = false;
    while (_index < _packets.length) {
      final packet = _packets[_index];
      final rel = packet.receivedAtMs - t0;
      if (rel > clock) break;
      _store.ingest(packet, sourceName: _fileName());
      _index++;
      ingested = true;
    }

    if (ingested) _store.notifyThrottled();
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
    if (!state.isActive || state.playing) return;
    if (_index >= _packets.length) {
      // Restart from the beginning when replaying a finished recording.
      seek(0);
    }
    _lastTickMs = DateTime.now().millisecondsSinceEpoch;
    state = state.copyWith(playing: true);
    _ticker = Timer.periodic(const Duration(milliseconds: 50), (_) => _tick());
  }

  void setSpeed(double speed) => state = state.copyWith(speed: speed);

  /// Jumps to [positionMs]: replays everything from the start instantly so
  /// the store's history and dead reckoning stay consistent.
  void seek(int positionMs) {
    if (_packets.isEmpty) return;

    _store.reset(sourceName: _fileName());
    final t0 = _packets.first.receivedAtMs;
    var index = 0;
    while (index < _packets.length) {
      if (_packets[index].receivedAtMs - t0 > positionMs) break;
      _store.ingest(_packets[index], sourceName: _fileName());
      index++;
    }
    _store.notifyThrottled();

    _index = index;
    state = state.copyWith(positionMs: positionMs);
  }

  /// Stops playback and returns the store to live mode.
  void stop() {
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
