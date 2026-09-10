import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:serial/serial.dart';

import '../../core/format.dart';
import '../../theme/app_colors.dart';
import '../components/app_card.dart';
import '../../state/workspace_controller.dart';
import '../../state/telemetry_provider.dart';
import '../../services/flight_trim.dart';
import './orbit_preview.dart';
import '../../state/replay_controller.dart';
import './router.dart';

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
          if (header != null && header.hasStats) {
            info.durationMs = header.durationMs;
            info.packets = header.packetCount;
            info.maxAltM = header.maxBaroAltM;
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
    await ref.read(replayProvider.notifier).play(recording.path);
    // Jump to the dashboard once a replay actually loaded;
    // load errors stay on this screen.
    if (!context.mounted) return;
    final replay = ref.read(replayProvider);
    if (replay.isActive && replay.errorMsg == null) {
      // Prefer the dedicated Replay workspace when present.
      final workspaces =
          ref.read(workspaceProvider).value?.workspaces ?? const [];
      for (final ws in workspaces) {
        if (ws.name == 'Replay') {
          await ref.read(workspaceProvider.notifier).setActive(ws.id);
          break;
        }
      }
      ref.read(appRouterProvider.notifier).go(AppScreen.dashboard);
    }
  }

  @override
  Widget build(BuildContext context) {
    final replay = ref.watch(replayProvider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
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
                  // Content budget: 20 card padding + ~32 header + 6 + 156
                  // preview + 6 + ~12 stats + 8 + 40 buttons ≈ 280.
                  mainAxisExtent: 288,
                  mainAxisSpacing: 8,
                  crossAxisSpacing: 8,
                ),
                itemCount: recordings.length,
                itemBuilder: (context, index) {
                  final recording = recordings[index];
                  final isLoaded = replay.filePath == recording.path;
                  return _RecordingCard(
                    info: recording,
                    isLoaded: isLoaded,
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

  /// Decimated barometric altitude series (≤160 pts) for thumbnails.
  List<double> altProfile = const [];

  /// Decimated GPS track (≤160 pts, oldest first) for the 3D orbit preview.
  List<TrackPoint> track = const [];

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
  });

  String get name => path.split(Platform.pathSeparator).last;

  String get directory => path.substring(0, path.length - name.length);

  Future<void> delete() async {
    final f = File(path);
    if (await f.exists()) await f.delete();
  }
}

class _RecordingCard extends StatefulWidget {
  final RecordingInfo info;
  final bool isLoaded;
  final VoidCallback onPlay;
  final VoidCallback onDelete;
  final VoidCallback onTrim;

  const _RecordingCard({
    required this.info,
    required this.isLoaded,
    required this.onPlay,
    required this.onDelete,
    required this.onTrim,
  });

  @override
  State<_RecordingCard> createState() => _RecordingCardState();
}

class _RecordingCardState extends State<_RecordingCard> {
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

  @override
  Widget build(BuildContext context) {
    final info = widget.info;
    final isLoaded = widget.isLoaded;
    final stats = <String>[
      if (info.durationMs != null) formatMinSec(info.durationMs!),
      if (info.packets != null) '${info.packets} packets',
      if (info.maxAltM != null) 'max ${formatAltitudeM(info.maxAltM)}',
      _sizeLabel,
    ];
    final date = formatDateTime(info.modified);

    return AppCard(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
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
              InkWell(
                onTap: widget.onDelete,
                borderRadius: BorderRadius.circular(4),
                child: Tooltip(
                  message: 'Delete recording',
                  child: const Padding(
                    padding: EdgeInsets.all(4),
                    child: Icon(Icons.delete_outline, size: 17),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          // Orbiting 3D track preview (altitude sparkline when the
          // recording holds no GPS fixes): the flight at a glance. Shows a
          // spinner until this card's own decode lands.
          SizedBox(
            height: 156,
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              decoration: BoxDecoration(
                color: AppColors.muted,
                borderRadius: BorderRadius.circular(AppDimens.radiusSmall),
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
                        child: CircularProgressIndicator(strokeWidth: 2),
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
          const SizedBox(height: 8),
          Row(
            children: [
              FilledButton.icon(
                onPressed: widget.onPlay,
                style: isLoaded
                    ? FilledButton.styleFrom(backgroundColor: AppColors.primary)
                    : null,
                icon: Icon(
                  isLoaded ? Icons.replay : Icons.play_arrow,
                  size: 16,
                ),
                label: Text(isLoaded ? 'Replay' : 'Open'),
              ),
              const SizedBox(width: 8),
              Tooltip(
                message: info.durationMs != null && info.durationMs! > 2000
                    ? 'Save part of this flight as a new file'
                    : 'Trim needs a flight longer than 2 s',
                child: OutlinedButton.icon(
                  onPressed: info.durationMs != null && info.durationMs! > 2000
                      ? widget.onTrim
                      : null,
                  icon: const Icon(Icons.content_cut_outlined, size: 16),
                  label: const Text('Trim…'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Trim preview: the full altitude profile dimmed, the kept window at full
/// strength with edge markers.
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
    // decode on demand so the altitude graph still shows.
    if (widget.info.altProfile.length < 2) {
      decodeRecordingFrames(widget.info.path).then((flight) {
        if (!mounted || flight.isEmpty) return;
        setState(() {
          widget.info.altProfile = buildAltProfile(flight.frames);
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
            // Altitude context with the kept window highlighted.
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
                  child: CustomPaint(
                    painter: _TrimChartPainter(
                      values: widget.info.altProfile,
                      startFrac: totalS <= 0 ? 0 : _startS / totalS,
                      endFrac: totalS <= 0 ? 1 : _endS / totalS,
                      color: AppColors.seriesAltitude,
                    ),
                    child: const SizedBox.expand(),
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
