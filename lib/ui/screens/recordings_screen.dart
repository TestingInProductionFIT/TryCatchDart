import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:serial/serial.dart';

import '../../core/format.dart';
import '../../core/geo.dart';
import '../../core/flight_events.dart';
import '../../theme/app_colors.dart';
import '../components/app_card.dart';
import '../components/flight_event_style.dart';
import '../../state/launch_site_store.dart';
import '../../state/workspace_controller.dart';
import '../../state/telemetry_provider.dart';
import '../../services/flight_trim.dart';
import './orbit_preview.dart';
import '../../state/replay_controller.dart';
import '../tiles/shared/map_tiles.dart';
import './router.dart';

/// Returns true when [site] already exists in [presets] — either under the
/// same name or within [toleranceM] horizontally of a saved preset (same
/// pad, re-recorded or renamed). Used to hide the per-recording
/// "extract launch position" button when there is nothing new to save.
bool isLaunchSiteSaved(
  List<LaunchSite> presets,
  LaunchSite site, {
  double toleranceM = 50,
}) {
  for (final preset in presets) {
    if (preset.name == site.name) return true;
    if (haversineDistanceM(
          preset.latitude,
          preset.longitude,
          site.latitude,
          site.longitude,
        ) <=
        toleranceM) {
      return true;
    }
  }
  return false;
}

/// Recorded flights: preview cards with decoded stats, replay, trim-to-new
/// ("save part of a flight") and delete, plus an open-folder shortcut.
class RecordingsScreen extends ConsumerStatefulWidget {
  const RecordingsScreen({super.key});

  @override
  ConsumerState<RecordingsScreen> createState() => _RecordingsScreenState();
}

class _RecordingsScreenState extends ConsumerState<RecordingsScreen> {
  late Future<List<RecordingInfo>> _recordings;
  String? _dirPath;
  String? _loadingPath;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  void _reload() {
    _recordings = _scanRecordings();
  }

  /// Stat-only scan: the grid renders immediately off names/sizes, and each
  /// card decodes its own preview concurrently (see [_RecordingCard]).
  /// Fully parsing every file up front would hold the whole list hostage to
  /// the slowest file. Decoded previews are cached for the session (keyed by
  /// path + size + mtime) so refreshes don't re-parse unchanged files.
  /// Headers yield duration/packets/max-alt straight from 108 bytes.
  final _infoCache = <String, RecordingInfo>{};

  Future<List<RecordingInfo>> _scanRecordings() async {
    final dirPath = await ref.read(recordingsDirectoryProvider.future);
    _dirPath = dirPath;
    final dir = Directory(dirPath);
    if (!await dir.exists()) return const [];

    final recordings = <RecordingInfo>[];
    final seen = <String>{};
    await for (final entity in dir.list()) {
      if (entity is! File || !entity.path.endsWith('.bin')) continue;
      try {
        final stat = await entity.stat();
        seen.add(entity.path);
        final cached = _infoCache[entity.path];
        if (cached != null &&
            cached.sizeBytes == stat.size &&
            cached.modified == stat.modified) {
          recordings.add(cached);
          continue;
        }
        final info = RecordingInfo(
          path: entity.path,
          sizeBytes: stat.size,
          modified: stat.modified,
        );
        try {
          final header = await tryReadRecordingHeader(entity.path);
          if (header != null) {
            info.launchSite = launchSiteFromHeader(header);
            if (header.hasStats) {
              info.durationMs = header.durationMs;
              info.packets = header.packetCount;
              info.maxAltM = header.maxBaroAltM;
            }
          }
        } catch (_) {
          // Header read is best-effort; the card decode fills stats instead.
        }
        _infoCache[entity.path] = info;
        recordings.add(info);
      } catch (_) {
        // Skip unreadable files.
      }
    }
    _infoCache.removeWhere((key, _) => !seen.contains(key));
    recordings.sort((a, b) => b.modified.compareTo(a.modified));
    return recordings;
  }

  Future<void> _openFolder() async {
    final dir = _dirPath;
    if (dir == null) return;
    try {
      if (Platform.isWindows) {
        await Process.start('explorer', [dir]);
      } else if (Platform.isMacOS) {
        await Process.start('open', [dir]);
      } else {
        await Process.start('xdg-open', [dir]);
      }
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not open the folder.')),
      );
    }
  }

  Future<void> _play(RecordingInfo recording) async {
    if (_loadingPath != null) return;
    // Opening a replay clears live buffers and hides the radio UI, so
    // confirm first when a recording is running or the radio is connected.
    // Replacing an already-open replay needs no confirmation.
    final serialStatus = ref.read(serialStatusProvider).value;
    final isRecording = serialStatus?.isRecording ?? false;
    final isConnected = serialStatus?.isConnected ?? false;
    if (isRecording) {
      if (!context.mounted) return;
      final confirm = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('Stop recording and open replay?'),
          content: const Text(
            'Opening a replay stops the current recording and clears live '
            'data. The recording file is kept.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('Stop & open'),
            ),
          ],
        ),
      );
      if (confirm != true) return;
      ref.read(serialConfigProvider.notifier).stopRecording();
    } else if (isConnected) {
      if (!context.mounted) return;
      final confirm = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('Open replay while connected?'),
          content: const Text(
            'Live telemetry is paused during a replay and current live '
            'data is cleared. The connection stays open — Back to live '
            '(×) returns to it.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('Open replay'),
            ),
          ],
        ),
      );
      if (confirm != true) return;
    }
    setState(() => _loadingPath = recording.path);
    try {
      await ref.read(replayProvider.notifier).play(recording.path);
    } finally {
      if (mounted) setState(() => _loadingPath = null);
    }
    // Jump to the dashboard once a replay actually loaded;
    // load errors stay on this screen.
    if (!context.mounted) return;
    final replay = ref.read(replayProvider);
    if (replay.isActive && replay.errorMsg == null) {
      // Always show the first layout — no heuristics.
      final workspaces =
          ref.read(workspaceProvider).value?.workspaces ?? const [];
      if (workspaces.isNotEmpty) {
        await ref
            .read(workspaceProvider.notifier)
            .setActive(workspaces.first.id);
      }
      ref.read(appRouterProvider.notifier).go(AppScreen.dashboard);
    }
  }

  @override
  Widget build(BuildContext context) {
    final replay = ref.watch(replayProvider);

    final isLoading = _loadingPath != null || replay.isLoading;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Reserved slot: inserting the progress bar must not push the grid
        // down (that 2px jump coincides with the pink card outline and
        // reads as the outline shifting the layout).
        SizedBox(
          height: 2,
          child: isLoading
              ? const LinearProgressIndicator(minHeight: 2)
              : const SizedBox.shrink(),
        ),
        if (replay.isActive && replay.errorMsg != null)
          // Playback controls live in the top bar; surface only load errors.
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            color: AppColors.destructive.withValues(alpha: 0.08),
            child: Text(
              replay.errorMsg!,
              style: TextStyle(fontSize: 12.5, color: AppColors.destructive),
            ),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(
            AppDimens.pagePadding,
            AppDimens.pagePadding,
            AppDimens.pagePadding,
            8,
          ),
          child: Row(
            children: [
              Text(
                'RECORDED FLIGHTS',
                style: AppText.microLabel.copyWith(letterSpacing: 1.4),
              ),
              const Spacer(),
              OutlinedButton.icon(
                onPressed: _openFolder,
                icon: const Icon(Icons.folder_open_outlined, size: 16),
                label: const Text('Open folder'),
              ),
              const SizedBox(width: 8),
              OutlinedButton.icon(
                onPressed: () => setState(_reload),
                icon: const Icon(Icons.refresh, size: 16),
                label: const Text('Refresh'),
              ),
            ],
          ),
        ),
        Expanded(
          child: FutureBuilder<List<RecordingInfo>>(
            future: _recordings,
            builder: (context, snapshot) {
              if (snapshot.connectionState != ConnectionState.done) {
                return const Center(child: CircularProgressIndicator());
              }
              final recordings = snapshot.data ?? const [];
              if (recordings.isEmpty) {
                return Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.flight,
                        size: 40,
                        color: AppColors.strongBorder,
                      ),
                      const SizedBox(height: 12),
                      const Text('No recordings yet'),
                      const SizedBox(height: 4),
                      Text(
                        'Connect a port, then hit Record in the top bar.',
                        style: TextStyle(
                          fontSize: 12,
                          color: AppColors.mutedForeground,
                        ),
                      ),
                      const SizedBox(height: 12),
                      FilledButton.icon(
                        onPressed: () => ref
                            .read(appRouterProvider.notifier)
                            .go(AppScreen.dashboard),
                        icon: const Icon(
                          Icons.space_dashboard_outlined,
                          size: 16,
                        ),
                        label: const Text('Go to dashboard'),
                      ),
                    ],
                  ),
                );
              }

              return GridView.builder(
                padding: const EdgeInsets.fromLTRB(
                  AppDimens.pagePadding,
                  0,
                  AppDimens.pagePadding,
                  AppDimens.pagePadding,
                ),
                gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                  maxCrossAxisExtent: 440,
                  // Content budget: 18 card padding + ~32 header + 6 + 200
                  // preview + 6 + ~12 stats (≈ 274). The transport lives on
                  // the preview (whole-preview tap target + center play
                  // button) and the rest hides in the header … menu, so no
                  // button rows and no dead space below the stats.
                  mainAxisExtent: 284,
                  mainAxisSpacing: 8,
                  crossAxisSpacing: 8,
                ),
                itemCount: recordings.length,
                itemBuilder: (context, index) {
                  final recording = recordings[index];
                  final isLoaded = replay.filePath == recording.path;
                  final cardLoading = _loadingPath == recording.path;
                  return _RecordingCard(
                    info: recording,
                    isLoaded: isLoaded,
                    isLoading: cardLoading,
                    busy: _loadingPath != null,
                    onPlay: () => _play(recording),
                    onDelete: () async {
                      await recording.delete();
                      setState(_reload);
                    },
                    onTrim: () async {
                      final saved = await showDialog<bool>(
                        context: context,
                        builder: (_) => _TrimDialog(info: recording),
                      );
                      if (saved == true) setState(_reload);
                    },
                  );
                },
              );
            },
          ),
        ),
      ],
    );
  }
}

/// Metadata + decoded preview about one `.bin` recording.
class RecordingInfo {
  final String path;
  final int sizeBytes;
  final DateTime modified;
  int? durationMs;
  int? packets;
  double? maxAltM;

  /// Launch pad position stamped into the file header (`null` for legacy
  /// siteless or unreadable files — nothing to extract then).
  LaunchSite? launchSite;

  /// Decimated barometric altitude series (≤160 pts) for thumbnails.
  List<double> altProfile = const [];

  /// Decimated GPS track (≤160 pts, oldest first) for the 3D orbit preview.
  List<TrackPoint> track = const [];

  /// Flight milestones (launch / apogee / …) detected from the preview decode,
  /// in frame order — shown as markers in the trim view.
  List<FlightEvent> events = const [];

  /// Whether the preview decode already ran (successfully or not) — cards
  /// skip re-decoding when the session cache hands them a known file.
  bool previewDone = false;

  RecordingInfo({
    required this.path,
    required this.sizeBytes,
    required this.modified,
    this.durationMs,
    this.packets,
    this.maxAltM,
    this.launchSite,
  });

  String get name => path.split(Platform.pathSeparator).last;

  String get directory => path.substring(0, path.length - name.length);

  Future<void> delete() async {
    final f = File(path);
    if (await f.exists()) await f.delete();
  }
}

class _RecordingCard extends ConsumerStatefulWidget {
  final RecordingInfo info;
  final bool isLoaded;
  final bool isLoading;
  final bool busy;
  final VoidCallback onPlay;
  final VoidCallback onDelete;
  final VoidCallback onTrim;

  const _RecordingCard({
    required this.info,
    required this.isLoaded,
    this.isLoading = false,
    this.busy = false,
    required this.onPlay,
    required this.onDelete,
    required this.onTrim,
  });

  @override
  ConsumerState<_RecordingCard> createState() => _RecordingCardState();
}

class _RecordingCardState extends ConsumerState<_RecordingCard> {
  bool _savingSite = false;
  @override
  void initState() {
    super.initState();
    // Each card decodes its own file concurrently after the grid is already
    // on screen — the list never waits for the slowest recording.
    if (!widget.info.previewDone) _loadPreview();
  }

  /// Decode pass for packet count, duration, max altitude, the altitude
  /// profile and the 3D track.
  ///
  /// Chunks hold raw stream fragments (not one packet each), so they go
  /// through the packet parser before decoding — decoding chunks directly
  /// yields nothing and renders a flat preview. Stats already known from
  /// the file header are kept; the decode only adds the visual profiles.
  Future<void> _loadPreview() async {
    try {
      final flight = await decodeRecordingFrames(widget.info.path);
      if (!mounted) return;
      setState(() {
        final info = widget.info;
        if (!flight.isEmpty) {
          final frames = flight.frames;
          info.packets ??= frames.length;
          info.durationMs ??=
              frames.last.receivedAtMs - frames.first.receivedAtMs;
          if (info.maxAltM == null) {
            var maxAlt = double.negativeInfinity;
            for (final frame in frames) {
              if (frame.baroAltitude > maxAlt) maxAlt = frame.baroAltitude;
            }
            if (maxAlt.isFinite) info.maxAltM = maxAlt;
          }
          info.altProfile = buildAltProfile(frames);
          info.track = buildTrackProfile(frames);
          info.events = detectFlightEvents(frames);
        }
        info.previewDone = true;
      });
    } catch (_) {
      // Preview stays empty; the file can still (maybe) replay.
      if (!mounted) return;
      setState(() => widget.info.previewDone = true);
    }
  }

  String get _sizeLabel {
    if (widget.info.sizeBytes >= 1024 * 1024) {
      return '${(widget.info.sizeBytes / 1024 / 1024).toStringAsFixed(1)} MB';
    }
    return '${(widget.info.sizeBytes / 1024).toStringAsFixed(0)} KB';
  }

  /// Saves this recording's header launch position as a preset. The button
  /// hides itself on completion because the preset list (watched in [build])
  /// then covers the site.
  Future<void> _saveLaunchSite(LaunchSite site) async {
    if (_savingSite) return;
    setState(() => _savingSite = true);
    try {
      await ref.read(launchSiteProvider.notifier).savePreset(site);
      unawaited(precacheLaunchSites([site]));
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Saved launch site "${site.name}".')),
      );
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not save the launch site.')),
      );
    } finally {
      if (mounted) setState(() => _savingSite = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final info = widget.info;
    final isLoaded = widget.isLoaded;
    final presets =
        ref.watch(launchSiteProvider).value?.presets ?? const <LaunchSite>[];
    final fileSite = info.launchSite;
    final showExtractSite =
        fileSite != null && !isLaunchSiteSaved(presets, fileSite);
    final canTrim = info.durationMs != null && info.durationMs! > 2000;
    final stats = <String>[
      if (info.durationMs != null) formatMinSec(info.durationMs!),
      if (info.packets != null) '${info.packets} packets',
      if (info.maxAltM != null) 'max ${formatAltitudeM(info.maxAltM)}',
      _sizeLabel,
    ];
    final date = formatDateTime(info.modified);

    return AppCard(
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 8),
      borderColor: isLoaded ? AppColors.primary : null,
      // NOTE: fixed heights only — grid tiles can arrive with an unbounded
      // height during layout, which an Expanded child would explode on.
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.flight_takeoff,
                size: 18,
                color: isLoaded ? AppColors.primary : AppColors.mutedForeground,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      info.name,
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                    Text(
                      date,
                      style: AppText.mono.copyWith(
                        fontSize: 10.5,
                        fontWeight: FontWeight.w600,
                        color: AppColors.mutedForeground,
                      ),
                    ),
                  ],
                ),
              ),
              PopupMenuButton<String>(
                tooltip: 'Recording actions',
                iconSize: 18,
                onSelected: (value) {
                  switch (value) {
                    case 'trim':
                      widget.onTrim();
                    case 'extract':
                      final site = fileSite;
                      if (site != null) _saveLaunchSite(site);
                    case 'delete':
                      widget.onDelete();
                  }
                },
                itemBuilder: (context) => [
                  PopupMenuItem(
                    value: 'trim',
                    enabled: canTrim,
                    child: const Row(
                      children: [
                        Icon(Icons.content_cut_outlined, size: 16),
                        SizedBox(width: 8),
                        Text('Trim…'),
                      ],
                    ),
                  ),
                  if (showExtractSite)
                    PopupMenuItem(
                      value: 'extract',
                      enabled: !_savingSite,
                      child: Row(
                        children: [
                          const Icon(Icons.pin_drop_outlined, size: 16),
                          const SizedBox(width: 8),
                          Text(_savingSite ? 'Saving…' : 'Extract site'),
                        ],
                      ),
                    ),
                  PopupMenuItem(
                    value: 'delete',
                    child: Row(
                      children: [
                        Icon(
                          Icons.delete_outline,
                          size: 16,
                          color: AppColors.destructive,
                        ),
                        const SizedBox(width: 8),
                        Text(
                          'Delete',
                          style: TextStyle(color: AppColors.destructive),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 6),
          // Orbiting 3D track preview (altitude sparkline when the
          // recording holds no GPS fixes): the flight at a glance. Shows a
          // spinner until this card's own decode lands. The whole preview
          // is the play affordance, as if it was a video — pink button in
          // the middle, pointer cursor, tap anywhere to open the replay.
          SizedBox(
            height: 200,
            child: Material(
              color: Colors.transparent,
              borderRadius: BorderRadius.circular(AppDimens.radiusSmall),
              clipBehavior: Clip.hardEdge,
              child: InkWell(
                onTap: widget.busy ? null : widget.onPlay,
                mouseCursor: widget.busy
                    ? SystemMouseCursors.basic
                    : SystemMouseCursors.click,
                child: Stack(
                  children: [
                    Positioned.fill(
                      child: Container(
                        width: double.infinity,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 6,
                        ),
                        decoration: BoxDecoration(
                          color: AppColors.muted,
                          borderRadius: BorderRadius.circular(
                            AppDimens.radiusSmall,
                          ),
                          border: Border.all(color: AppColors.border),
                        ),
                        child: info.previewDone
                            ? OrbitOrSparkline(
                                track: info.track,
                                altProfile: info.altProfile,
                              )
                            : const Center(
                                child: SizedBox(
                                  width: 14,
                                  height: 14,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                ),
                              ),
                      ),
                    ),
                    Center(
                      child: Opacity(
                        opacity: widget.busy && !widget.isLoading ? 0.55 : 1,
                        child: Container(
                          width: 50,
                          height: 50,
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: AppColors.primary.withValues(alpha: 0.4),
                          ),
                          child: widget.isLoading
                              ? const SizedBox(
                                  width: 26,
                                  height: 26,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2.5,
                                    color: Colors.white,
                                  ),
                                )
                              : Icon(
                                  isLoaded ? Icons.replay : Icons.play_arrow,
                                  size: 30,
                                  color: Colors.white,
                                ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            stats.join(' · ').toUpperCase(),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: AppText.microLabel.copyWith(
              fontSize: 9,
              letterSpacing: 0.8,
              color: AppColors.mutedForeground,
            ),
          ),
        ],
      ),
    );
  }
}

/// Trim preview: the full altitude profile dimmed, the kept window at full
/// strength with edge markers, plus flight-event dots on the curve.
///
/// Public (not `_`-private) so widget tests can pump it directly — the
/// surrounding card/dialog touch the filesystem and can't run in the
/// fake-async test zone.
class TrimChart extends StatelessWidget {
  final List<double> values;
  final List<FlightEvent> events;
  final int totalMs;
  final int startMs;
  final int endMs;
  final Color color;

  /// Diameter of one event dot on the trim chart.
  static const double dotSize = 14;

  const TrimChart({
    super.key,
    required this.values,
    required this.events,
    required this.totalMs,
    required this.startMs,
    required this.endMs,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    final startFrac = totalMs <= 0
        ? 0.0
        : (startMs / totalMs).clamp(0.0, 1.0).toDouble();
    final endFrac = totalMs <= 0
        ? 1.0
        : (endMs / totalMs).clamp(0.0, 1.0).toDouble();
    return LayoutBuilder(
      builder: (context, constraints) {
        final w = constraints.maxWidth;
        final h = constraints.maxHeight;
        return Stack(
          children: [
            Positioned.fill(
              child: CustomPaint(
                painter: _TrimChartPainter(
                  values: values,
                  startFrac: startFrac,
                  endFrac: endFrac,
                  color: color,
                ),
              ),
            ),
            for (final dot in _placeDots(w, h))
              Positioned(
                left: dot.x - dotSize / 2,
                top: dot.y - dotSize / 2,
                width: dotSize,
                height: dotSize,
                child: Tooltip(
                  message:
                      '${dot.event.type.label} at ${formatMinSec(dot.event.positionMs)}'
                      '${dot.kept ? '' : ' — outside kept slice'}',
                  child: FlightEventDot(
                    type: dot.event.type,
                    size: dotSize,
                    dimmed: !dot.kept,
                  ),
                ),
              ),
          ],
        );
      },
    );
  }

  /// Resolves each event to a dot centre on the altitude curve: x from the
  /// flight-clock fraction (the same time base as the kept-window edges), y
  /// from the decimated profile value nearest that fraction. Dots landing
  /// within one diameter of an earlier dot nudge downward so stacked markers
  /// never paint on top of each other; x (the true position) never moves.
  List<_TrimDot> _placeDots(double w, double h) {
    final dots = <_TrimDot>[];
    if (events.isEmpty ||
        totalMs <= 0 ||
        w <= 0 ||
        h <= 0 ||
        !_wHFinite(w, h)) {
      return dots;
    }
    var lo = double.infinity;
    var hi = double.negativeInfinity;
    for (final v in values) {
      if (v < lo) lo = v;
      if (v > hi) hi = v;
    }
    final flat = values.length < 2 || !lo.isFinite || (hi - lo).abs() < 1e-9;
    const pad = 4.0;
    double yAt(double frac) {
      if (flat) return h / 2;
      final idx = (frac * (values.length - 1)).round().clamp(
        0,
        values.length - 1,
      );
      return pad + (h - 2 * pad) * (1 - (values[idx] - lo) / (hi - lo));
    }

    for (final event in events) {
      final frac = (event.positionMs / totalMs).clamp(0.0, 1.0).toDouble();
      var y = yAt(frac);
      // De-collide against already-placed dots (time order = list order).
      var nudges = 0;
      while (nudges < 2) {
        var collides = false;
        final x = pad + (w - 2 * pad) * frac;
        for (final other in dots) {
          final dx = x - other.x;
          final dy = y - other.y;
          if (dx * dx + dy * dy < dotSize * dotSize) {
            collides = true;
            break;
          }
        }
        if (!collides) break;
        y += dotSize;
        nudges++;
      }
      final x = pad + (w - 2 * pad) * frac;
      dots.add(
        _TrimDot(
          event: event,
          x: x.clamp(0.0, w),
          y: y.clamp(0.0, h),
          kept: event.positionMs >= startMs && event.positionMs <= endMs,
        ),
      );
    }
    return dots;
  }

  static bool _wHFinite(double w, double h) => w.isFinite && h.isFinite;
}

/// One trim-chart marker resolved to a pixel centre.
class _TrimDot {
  final FlightEvent event;
  final double x;
  final double y;
  final bool kept;

  const _TrimDot({
    required this.event,
    required this.x,
    required this.y,
    required this.kept,
  });
}

/// Paints the trim preview: the full altitude profile dimmed, the kept
/// window at full strength with edge markers. (Event dots are widgets
/// overlaid by [TrimChart], not paint, so they keep tooltips.)
class _TrimChartPainter extends CustomPainter {
  final List<double> values;
  final double startFrac;
  final double endFrac;
  final Color color;

  const _TrimChartPainter({
    required this.values,
    required this.startFrac,
    required this.endFrac,
    required this.color,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width <= 0 || size.height <= 0 || values.length < 2) return;
    var lo = double.infinity;
    var hi = double.negativeInfinity;
    for (final v in values) {
      if (v < lo) lo = v;
      if (v > hi) hi = v;
    }
    if (!lo.isFinite || (hi - lo).abs() < 1e-9) return;
    const pad = 4.0;
    final n = values.length;
    Offset pt(int i) => Offset(
      pad + (size.width - 2 * pad) * i / (n - 1),
      pad + (size.height - 2 * pad) * (1 - (values[i] - lo) / (hi - lo)),
    );
    final path = Path()..moveTo(pt(0).dx, pt(0).dy);
    for (var i = 1; i < n; i++) {
      path.lineTo(pt(i).dx, pt(i).dy);
    }
    final line = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5
      ..strokeJoin = StrokeJoin.round;

    // Full profile, dimmed.
    canvas.drawPath(path, line..color = color.withValues(alpha: 0.3));

    // Kept window: shade + bright redraw clipped to it.
    final left = startFrac.clamp(0.0, 1.0) * size.width;
    final right = endFrac.clamp(0.0, 1.0) * size.width;
    canvas.drawRect(
      Rect.fromLTRB(left, 0, right, size.height),
      Paint()..color = color.withValues(alpha: 0.10),
    );
    canvas.save();
    canvas.clipRect(Rect.fromLTRB(left, 0, right, size.height));
    canvas.drawPath(path, line..color = color);
    canvas.restore();

    // Edge markers.
    final edge = Paint()
      ..color = AppColors.primary
      ..strokeWidth = 1.5;
    canvas.drawLine(Offset(left, 0), Offset(left, size.height), edge);
    canvas.drawLine(Offset(right, 0), Offset(right, size.height), edge);
  }

  @override
  bool shouldRepaint(covariant _TrimChartPainter old) =>
      !identical(old.values, values) ||
      old.startFrac != startFrac ||
      old.endFrac != endFrac ||
      old.color != color;
}

/// Trims a time slice of a recording into a new `.bin` file.
class _TrimDialog extends StatefulWidget {
  final RecordingInfo info;

  const _TrimDialog({required this.info});

  @override
  State<_TrimDialog> createState() => _TrimDialogState();
}

class _TrimDialogState extends State<_TrimDialog> {
  late double _startS;
  late double _endS;
  late final TextEditingController _name;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    final totalS = (widget.info.durationMs ?? 0) / 1000;
    _startS = 0;
    _endS = totalS;
    final base = widget.info.name.replaceAll('.bin', '');
    _name = TextEditingController(text: '${base}_trim');
    // Self-heal: if the card preview never decoded (stale/empty profile),
    // decode on demand so the altitude graph and event markers still show.
    if (widget.info.altProfile.length < 2 || !widget.info.previewDone) {
      decodeRecordingFrames(widget.info.path).then((flight) {
        if (!mounted || flight.isEmpty) return;
        setState(() {
          if (widget.info.altProfile.length < 2) {
            widget.info.altProfile = buildAltProfile(flight.frames);
          }
          widget.info.events = detectFlightEvents(flight.frames);
        });
      });
    }
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final fileName = _name.text.trim();
    if (fileName.isEmpty || fileName.contains(Platform.pathSeparator)) {
      setState(() => _error = 'Give the clip a plain file name.');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final dst = '${widget.info.directory}$fileName.bin';
      if (await File(dst).exists()) {
        if (!mounted) return;
        setState(() {
          _error = 'A file with that name already exists.';
          _saving = false;
        });
        return;
      }
      final kept = await trimRecording(
        srcPath: widget.info.path,
        dstPath: dst,
        startMs: (_startS * 1000).round(),
        endMs: (_endS * 1000).round(),
      );
      if (!mounted) return;
      if (kept == 0) {
        setState(() {
          _error = 'The selected slice holds no packets.';
          _saving = false;
        });
        return;
      }
      Navigator.of(context).pop(true);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Saved $fileName.bin ($kept packets).')),
      );
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _error = 'Could not write the clip.';
        _saving = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final totalS = (widget.info.durationMs ?? 0) / 1000;
    return AlertDialog(
      title: const Text('Trim flight', style: TextStyle(fontSize: 16)),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Keep ${formatMinSec((_startS * 1000).round())} – '
              '${formatMinSec((_endS * 1000).round())} '
              'of ${formatMinSec(widget.info.durationMs ?? 0)}.',
              style: AppText.mono.copyWith(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: AppColors.mutedForeground,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
            // Altitude context with the kept window highlighted and flight
            // milestones marked on the curve (dimmed outside the kept slice).
            if (widget.info.altProfile.length >= 2) ...[
              const SizedBox(height: 8),
              SizedBox(
                height: 110,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    color: AppColors.muted,
                    borderRadius: BorderRadius.circular(AppDimens.radiusSmall),
                    border: Border.all(color: AppColors.border),
                  ),
                  child: TrimChart(
                    values: widget.info.altProfile,
                    events: widget.info.events,
                    totalMs: widget.info.durationMs ?? 0,
                    startMs: (_startS * 1000).round(),
                    endMs: (_endS * 1000).round(),
                    color: AppColors.seriesAltitude,
                  ),
                ),
              ),
            ],
            RangeSlider(
              values: RangeValues(_startS, _endS),
              min: 0,
              max: totalS,
              divisions: totalS.ceil().clamp(1, 1200),
              labels: RangeLabels(
                formatMinSec((_startS * 1000).round()),
                formatMinSec((_endS * 1000).round()),
              ),
              onChanged: _saving
                  ? null
                  : (v) => setState(() {
                      _startS = v.start;
                      _endS = v.end;
                    }),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _name,
              enabled: !_saving,
              decoration: const InputDecoration(
                labelText: 'New file name',
                suffixText: '.bin',
              ),
            ),
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(
                _error!,
                style: TextStyle(color: AppColors.destructive, fontSize: 12),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: (_saving || _endS <= _startS) ? null : _save,
          child: _saving
              ? const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Save clip'),
        ),
      ],
    );
  }
}
