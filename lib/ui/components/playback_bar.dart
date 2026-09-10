import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/replay_controller.dart';
import '../../theme/app_colors.dart';
import '../../core/format.dart';

/// Playback controls shown in the top bar while a replay is active.
///
/// Replaces the serial connection and recording groups — the app is replaying
/// recorded telemetry, not listening to the radio. File name, transport,
/// seek, speed and a constant "Back to live" close action.
class PlaybackBar extends ConsumerWidget {
  const PlaybackBar({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(replayProvider);
    final controller = ref.read(replayProvider.notifier);

    final duration = state.durationMs ?? 0;
    final position = state.positionMs.clamp(0, duration);
    final finished =
        !state.playing && duration > 0 && state.positionMs >= duration;

    return Row(
      children: [
        const _ReplayBadge(),
        // At the end the transport becomes a restart affordance — resume()
        // seeks back to 0 when the recording is finished.
        IconButton(
          tooltip: finished
              ? 'Replay from the start'
              : (state.playing ? 'Pause' : 'Play'),
          onPressed: () =>
              state.playing ? controller.pause() : controller.resume(),
          icon: Icon(
            finished
                ? Icons.replay
                : (state.playing ? Icons.pause : Icons.play_arrow),
            size: 20,
            color: AppColors.pinkDeep,
          ),
        ),
        // Playhead clock (repaints ~20 Hz while playing) — display only.
        ExcludeSemantics(
          child: Text(
            '${formatMinSec(position)} / ${formatMinSec(duration)}',
            style: AppText.mono.copyWith(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: AppColors.mutedForeground,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ),
        const SizedBox(width: 4),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Slider(
              value: duration == 0 ? 0 : position / duration,
              onChanged: duration == 0
                  ? null
                  : (v) => controller.seek((v * duration).round()),
              // Grabbing the timeline pauses so the ticker stops fighting
              // the scrub; playback stays paused until the user resumes.
              onChangeStart: duration == 0 ? null : (_) => controller.pause(),
            ),
          ),
        ),
        const SizedBox(width: 4),
        _SpeedMenu(speed: state.speed, onSelect: controller.setSpeed),
        const SizedBox(width: 8),
        // Constant close action — same look whether mid-replay or finished.
        OutlinedButton.icon(
          onPressed: controller.stop,
          style: OutlinedButton.styleFrom(
            foregroundColor: AppColors.pinkDeep,
            side: BorderSide(color: AppColors.pinkDeep),
          ),
          icon: const Icon(Icons.podcasts_outlined, size: 16),
          label: const Text('Back to live'),
        ),
      ],
    );
  }
}

/// Replay filename + tooltip, watching the file path only.
///
/// The playhead rebuilds this bar ~20 Hz while playing; keeping the bare
/// filename Tooltip out of those rebuilds keeps its overlay graft stable
/// (a rebuilding graft + hover is what trips the Windows AXTree bridge —
/// flutter/flutter#182444 family).
class _ReplayBadge extends ConsumerWidget {
  const _ReplayBadge();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final fileName = ref.watch(
      replayProvider.select(
        (s) => s.filePath?.split(Platform.pathSeparator).last ?? 'recording',
      ),
    );
    return Tooltip(
      message: 'Replaying $fileName — the radio is not being listened to',
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 180),
        child: Text(
          fileName,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: AppText.mono.copyWith(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: AppColors.mutedForeground,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
      ),
    );
  }
}

/// Playback-speed picker: a compact popup instead of a row of chips.
class _SpeedMenu extends StatelessWidget {
  final double speed;
  final ValueChanged<double> onSelect;

  const _SpeedMenu({required this.speed, required this.onSelect});

  static String _label(double s) => s >= 999 ? 'MAX' : '${s.toInt()}×';

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<double>(
      initialValue: speed,
      tooltip: 'Playback speed',
      onSelected: onSelect,
      itemBuilder: (context) => [
        for (final s in ReplayController.speeds)
          PopupMenuItem(
            value: s,
            child: Text(
              _label(s),
              style: TextStyle(
                fontFamily: AppText.monoFamily,
                fontWeight: FontWeight.w700,
                color: s == speed ? AppColors.pinkDeep : AppColors.foreground,
              ),
            ),
          ),
      ],
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(AppDimens.radiusSmall),
          border: Border.all(color: AppColors.strongBorder),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              _label(speed),
              style: AppText.mono.copyWith(
                fontSize: 11.5,
                fontWeight: FontWeight.w700,
                color: AppColors.mutedForeground,
              ),
            ),
            const SizedBox(width: 2),
            Icon(
              Icons.arrow_drop_down,
              size: 16,
              color: AppColors.mutedForeground,
            ),
          ],
        ),
      ),
    );
  }
}
