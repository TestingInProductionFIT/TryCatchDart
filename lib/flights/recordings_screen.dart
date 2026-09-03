import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../theme/app_colors.dart';
import '../theme/widgets/app_card.dart';
import '/src/telemetry/telemetry_provider.dart';
import 'replay_controller.dart';
import '../app/router.dart';

/// Recorded flights: lists the recordings folder and replays any flight.
class RecordingsScreen extends ConsumerStatefulWidget {
  const RecordingsScreen({super.key});

  @override
  ConsumerState<RecordingsScreen> createState() => _RecordingsScreenState();
}

class _RecordingsScreenState extends ConsumerState<RecordingsScreen> {
  late Future<List<RecordingInfo>> _recordings;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  void _reload() {
    _recordings = _scanRecordings();
  }

  Future<List<RecordingInfo>> _scanRecordings() async {
    final dirPath = await ref.read(recordingsDirectoryProvider.future);
    final dir = Directory(dirPath);
    if (!await dir.exists()) return const [];

    final recordings = <RecordingInfo>[];
    await for (final entity in dir.list()) {
      if (entity is! File || !entity.path.endsWith('.bin')) continue;
      try {
        final stat = await entity.stat();
        final info = RecordingInfo(
          path: entity.path,
          sizeBytes: stat.size,
          modified: stat.modified,
        );
        await _fillDuration(info);
        recordings.add(info);
      } catch (_) {
        // Skip unreadable files.
      }
    }
    recordings.sort((a, b) => b.modified.compareTo(a.modified));
    return recordings;
  }

  /// Walks the 12-byte chunk headers to find first/last packet timestamps.
  Future<void> _fillDuration(RecordingInfo info) async {
    try {
      final reader = await File(info.path).open();
      try {
        final length = await reader.length();
        int? firstMs;
        int? lastMs;

        var position = 0;
        while (position + 12 <= length) {
          await reader.setPosition(position);
          final header = ByteData.sublistView(await reader.read(12));
          final tsMs = header.getInt64(0, Endian.big) ~/ 1000;
          final payloadLength = header.getUint32(8, Endian.big);
          if (position + 12 + payloadLength > length) break;

          firstMs ??= tsMs;
          lastMs = tsMs;
          position += 12 + payloadLength;

          // Cap scan time for pathological files.
          if (position > 512 * 1024 * 1024) break;
        }

        info.durationMs =
            firstMs != null && lastMs != null ? lastMs - firstMs : null;
      } finally {
        await reader.close();
      }
    } catch (_) {
      info.durationMs = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final replay = ref.watch(replayProvider);

    return Column(
      children: [
        if (replay.isActive && replay.errorMsg != null)
          // Playback controls live in the top bar; surface only load errors.
          Container(
            width: double.infinity,
            padding:
                const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            color: AppColors.destructive.withValues(alpha: 0.08),
            child: Text(
              replay.errorMsg!,
              style: const TextStyle(
                  fontSize: 12.5, color: AppColors.destructive),
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
                      const Icon(Icons.flight,
                          size: 40, color: AppColors.strongBorder),
                      const SizedBox(height: 12),
                      const Text('No recordings yet'),
                      const SizedBox(height: 4),
                      const Text(
                        'Hit Record in the top bar while connected.',
                        style: TextStyle(
                            fontSize: 12, color: AppColors.mutedForeground),
                      ),
                      const SizedBox(height: 12),
                      OutlinedButton.icon(
                        onPressed: () => setState(_reload),
                        icon: const Icon(Icons.refresh, size: 16),
                        label: const Text('Refresh'),
                      ),
                    ],
                  ),
                );
              }

              return ListView.separated(
                padding: const EdgeInsets.all(AppDimens.pagePadding),
                itemCount: recordings.length + 1,
                separatorBuilder: (_, _) => const SizedBox(height: 8),
                itemBuilder: (context, index) {
                  if (index == recordings.length) {
                    return Center(
                      child: OutlinedButton.icon(
                        onPressed: () => setState(_reload),
                        icon: const Icon(Icons.refresh, size: 16),
                        label: const Text('Refresh'),
                      ),
                    );
                  }
                  final recording = recordings[index];
                  final isLoaded = replay.filePath == recording.path;
                  return _RecordingTile(
                    info: recording,
                    isLoaded: isLoaded,
                    onPlay: () async {
                      await ref
                          .read(replayProvider.notifier)
                          .play(recording.path);
                      // Jump to the dashboard once a replay actually loaded;
                      // load errors stay on this screen.
                      if (!context.mounted) return;
                      final replay = ref.read(replayProvider);
                      if (replay.isActive && replay.errorMsg == null) {
                        ref
                            .read(appRouterProvider.notifier)
                            .go(AppScreen.dashboard);
                      }
                    },
                    onDelete: () async {
                      await recording.delete();
                      setState(_reload);
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

/// Metadata about one `.bin` recording.
class RecordingInfo {
  final String path;
  final int sizeBytes;
  final DateTime modified;
  int? durationMs;

  RecordingInfo({
    required this.path,
    required this.sizeBytes,
    required this.modified,
    this.durationMs,
  });

  String get name => path.split(Platform.pathSeparator).last;

  Future<void> delete() async {
    final f = File(path);
    if (await f.exists()) await f.delete();
  }
}

class _RecordingTile extends StatelessWidget {
  final RecordingInfo info;
  final bool isLoaded;
  final VoidCallback onPlay;
  final VoidCallback onDelete;

  const _RecordingTile({
    required this.info,
    required this.isLoaded,
    required this.onPlay,
    required this.onDelete,
  });

  String get _sizeLabel {
    if (info.sizeBytes >= 1024 * 1024) {
      return '${(info.sizeBytes / 1024 / 1024).toStringAsFixed(1)} MB';
    }
    return '${(info.sizeBytes / 1024).toStringAsFixed(0)} KB';
  }

  String get _durationLabel {
    final d = info.durationMs;
    if (d == null) return '—';
    final minutes = d ~/ 60000;
    final seconds = (d % 60000) ~/ 1000;
    return '$minutes:${seconds.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    return AppCard(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      borderColor: isLoaded ? AppColors.primary : null,
      child: Row(
        children: [
          Icon(
            Icons.flight_takeoff,
            size: 20,
            color: isLoaded ? AppColors.primary : AppColors.mutedForeground,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  info.name,
                  style: const TextStyle(
                      fontSize: 13.5, fontWeight: FontWeight.w600),
                  overflow: TextOverflow.ellipsis,
                ),
                Text(
                  '${info.modified.year}-${info.modified.month.toString().padLeft(2, '0')}-${info.modified.day.toString().padLeft(2, '0')} '
                  '${info.modified.hour.toString().padLeft(2, '0')}:${info.modified.minute.toString().padLeft(2, '0')} · '
                  '$_durationLabel · $_sizeLabel',
                  style: AppText.mono.copyWith(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: AppColors.mutedForeground),
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: 'Delete recording',
            onPressed: onDelete,
            icon: const Icon(Icons.delete_outline, size: 18),
          ),
          const SizedBox(width: 4),
          FilledButton.icon(
            onPressed: onPlay,
            style: isLoaded
                ? FilledButton.styleFrom(backgroundColor: AppColors.primary)
                : null,
            icon: Icon(
              isLoaded ? Icons.replay : Icons.play_arrow,
              size: 16,
            ),
            label: Text(isLoaded ? 'Replay' : 'Open'),
          ),
        ],
      ),
    );
  }
}

