import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../flights/replay_controller.dart';
import '../theme/app_colors.dart';
import 'format.dart';

/// Playback controls shown in the top bar while a replay is active.
///
/// Replaces the serial connection and recording groups — the app is replaying
/// recorded telemetry, not listening to the radio. Includes a prominent
/// "Back to live" action (also shown highlighted when the replay reaches the
/// end) and play/pause, seeking and speed.
class PlaybackBar extends ConsumerWidget {
  const PlaybackBar({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(replayProvider);
    final controller = ref.read(replayProvider.notifier);

    final duration = state.durationMs ?? 0;
    final position = state.positionMs.clamp(0, duration);
    final finished = !state.playing &&
        duration > 0 &&
        state.positionMs >= duration;

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          'REPLAY',
          style: AppText.microLabel.copyWith(fontSize: 8.5, color: AppColors.pinkDeep),
        ),
        const SizedBox(width: 10),
        IconButton(
          tooltip: state.playing ? 'Pause' : 'Play',
          onPressed: () =>
              state.playing ? controller.pause() : controller.resume(),
          icon: Icon(
            state.playing ? Icons.pause : Icons.play_arrow,
            size: 20,
            color: AppColors.pinkDeep,
          ),
        ),
        Text(
          '${formatMinSec(position)} / ${formatMinSec(duration)}',
          style: AppText.mono.copyWith(
            fontSize: 12,
            fontWeight: FontWeight.w700,
            color: AppColors.mutedForeground,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
        const SizedBox(width: 8),
        SizedBox(
          width: 320,
          child: Slider(
            value: duration == 0 ? 0 : position / duration,
            onChanged: duration == 0
                ? null
                : (v) => controller.seek((v * duration).round()),
            // Grabbing the timeline pauses so the ticker stops fighting
            // the scrub; playback stays paused until the user resumes.
            onChangeStart:
                duration == 0 ? null : (_) => controller.pause(),
          ),
        ),
        for (final speed in ReplayController.speeds)
          Padding(
            padding: const EdgeInsets.only(left: 4),
            child: ChoiceChip(
              label: Text(speed >= 999 ? 'MAX' : '${speed.toInt()}×'),
              selected: state.speed == speed,
              onSelected: (_) => controller.setSpeed(speed),
              labelStyle: TextStyle(
                fontSize: 11,
                fontFamily: AppText.monoFamily,
                fontWeight: FontWeight.w700,
                color: state.speed == speed
                    ? AppColors.pinkDeep
                    : AppColors.mutedForeground,
              ),
              visualDensity: VisualDensity.compact,
            ),
          ),
        const SizedBox(width: 8),
        finished
            ? FilledButton.icon(
                style: FilledButton.styleFrom(
                  backgroundColor: AppColors.success,
                  foregroundColor: Colors.white,
                ),
                onPressed: controller.stop,
                icon: const Icon(Icons.podcasts, size: 16),
                label: const Text('Replay finished — back to live'),
              )
            : OutlinedButton.icon(
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
