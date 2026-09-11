import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/replay_controller.dart';
import '../../theme/app_colors.dart';
import '../../core/flight_events.dart';
import '../../core/format.dart';
import './flight_event_style.dart';

/// Playback controls shown in the top bar while a replay is active.
///
/// Replaces the serial connection and recording groups — the app is replaying
/// recorded telemetry, not listening to the radio. File name, transport,
/// seek and speed. The constant "Back to live" close action lives in the
/// top-bar menu slot (see TopBar), in the exact spot the hamburger button
/// occupies when live.
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
    // While a recording is decoding (play() in flight) the replay state is
    // incomplete: no frames, no duration, no ticker. All transport actions
    // must stay disabled until loading finishes. (The "Back to live" close
    // action lives in the top-bar menu slot and is gated the same way.)
    final isLoading = state.isLoading;

    return Row(
      children: [
        const _ReplayBadge(),
        // At the end the transport becomes a restart affordance — toggle()
        // seeks back to 0 when the recording is finished.
        IconButton(
          tooltip: finished
              ? 'Replay from the start'
              : (state.playing ? 'Pause' : 'Play'),
          // toggle() keys off the live ticker, not just the last-published
          // flag, so the button can never desync from actual playback.
          onPressed: isLoading ? null : controller.toggle,
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
            child: _ReplayTimeline(duration: duration, position: position),
          ),
        ),
        const SizedBox(width: 4),
        _SpeedMenu(
          speed: state.speed,
          onSelect: controller.setSpeed,
          enabled: !isLoading,
        ),
        // Replay-only 3D display smoothing (trail + rotation). The file,
        // charts and map stay raw — this only changes how the 3D tiles paint.
        // NOTE: the "Back to live" close action lives in the top-bar menu
        // slot (same spot/size as the hamburger button), not in this row.
        IconButton(
          tooltip: state.smoothingEnabled
              ? 'Display smoothing on (3D trail + rotation) — tap for raw'
              : 'Display smoothing off — tap to smooth the 3D display',
          onPressed: isLoading
              ? null
              : () => controller.setSmoothing(!state.smoothingEnabled),
          icon: Icon(
            Icons.blur_on,
            size: 20,
            color: state.smoothingEnabled
                ? AppColors.pinkDeep
                : AppColors.mutedForeground,
          ),
        ),
      ],
    );
  }
}

/// Scrub slider with flight-milestone markers overlaid on the track.
///
/// Markers come from [replayFlightEventsProvider] (one per nominal FSM
/// transition in the loaded recording — zero, one or several of each type).
/// Each marker seeks the replay to its flight-clock position when tapped.
/// The marker buttons themselves only rebuild when the loaded flight changes;
/// the played/upcoming dimming inside each dot is a leaf consumer on the
/// playhead, so the tooltip grafts stay stable at the ~20 Hz repaint rate.
///
/// Marker dots share the slider's exact value→pixel mapping (see
/// [_timelineThumbTravel]), and markers that would paint on top of each
/// other are spread into alternating lanes above/below the track with a tick
/// back to the true position ([placeFlightEvents]).
class _ReplayTimeline extends ConsumerWidget {
  final int duration;
  final int position;

  const _ReplayTimeline({required this.duration, required this.position});

  /// Pinned slider geometry. These are the Material 3 defaults, so the
  /// slider looks exactly as before — but pinning them fixes the thumb
  /// travel by construction: with `padding: null` the track is inset by
  /// `max(overlay, thumb) / 2` on each side
  /// (`BaseSliderTrackShape.getPreferredRect`), i.e. 24 px from the r24
  /// overlay, and the thumb center runs from 24 to `width - 24`.
  /// [_timelineInsetPx] mirrors that inset so markers sit on the thumb path.
  static const _thumbShape = RoundSliderThumbShape();
  static const _overlayShape = RoundSliderOverlayShape();

  static double _timelineInsetPx() {
    final thumb = _thumbShape.getPreferredSize(true, false).width / 2;
    final overlay = _overlayShape.getPreferredSize(true, false).width / 2;
    return math.max(thumb, overlay);
  }

  /// Hit target for one marker. Kept tight around the dot on purpose:
  /// stacked lanes sit 16 px apart, so roomy targets would overlap and a
  /// tap would fire two seeks.
  static const double _hitSize = 16;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller = ref.read(replayProvider.notifier);
    final events = ref.watch(replayFlightEventsProvider);
    final isLoading = ref.watch(replayProvider.select((s) => s.isLoading));

    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final inset = _timelineInsetPx();
        final placements = placeFlightEvents(
          events,
          duration,
          widthPx: width,
          trackLeftPx: inset,
          trackWidthPx: math.max(0.0, width - 2 * inset),
        );
        // The slider track is vertically centered in its box and the slider
        // is the size-determining child of this stack, so the track center
        // is the stack's vertical midpoint.
        final height = constraints.maxHeight;
        final centerY = height.isFinite ? height / 2 : null;
        return Stack(
          children: [
            SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackHeight: 4,
                thumbShape: _thumbShape,
                overlayShape: _overlayShape,
                padding: null,
              ),
              child: Slider(
                value: duration == 0 ? 0 : position / duration,
                onChanged: duration == 0 || isLoading
                    ? null
                    : (v) => controller.seek((v * duration).round()),
                // Grabbing the timeline pauses so the ticker stops fighting
                // the scrub; playback stays paused until the user resumes.
                onChangeStart: duration == 0 || isLoading
                    ? null
                    : (_) => controller.pause(),
              ),
            ),
            if (placements.isNotEmpty && centerY != null)
              Positioned.fill(
                // Unclipped: edge markers render fully, exactly like the
                // slider thumb overflowing at the extremes — and, more
                // importantly, dots are never shifted away from their true
                // position to fit an arbitrary box.
                child: Stack(
                  clipBehavior: Clip.none,
                  children: [
                    for (final p in placements) ...[
                      if (p.dyPx != 0)
                        Positioned(
                          left: p.xPx - 1,
                          width: 2,
                          top: p.dyPx < 0
                              ? centerY + p.dyPx + flightEventDotDiameterPx / 2
                              : centerY,
                          height: p.dyPx.abs() - flightEventDotDiameterPx / 2,
                          child: IgnorePointer(
                            child: _EventTick(event: p.event),
                          ),
                        ),
                      Positioned(
                        left: p.xPx - _hitSize / 2,
                        top: centerY + p.dyPx - _hitSize / 2,
                        width: _hitSize,
                        height: _hitSize,
                        child: IconButton(
                          tooltip:
                              '${p.event.type.label} at ${formatMinSec(p.event.positionMs)} — tap to seek',
                          onPressed: isLoading
                              ? null
                              : () => controller.seek(p.event.positionMs),
                          style: IconButton.styleFrom(
                            minimumSize: const Size(_hitSize, _hitSize),
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                            padding: EdgeInsets.zero,
                          ),
                          icon: _EventDot(event: p.event),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
          ],
        );
      },
    );
  }
}

/// Thin connector from an off-track marker dot back to its exact position
/// on the track. Purely visual (the button does the seeking) and static —
/// no playhead subscription, no rebuild churn.
class _EventTick extends StatelessWidget {
  final FlightEvent event;

  const _EventTick({required this.event});

  @override
  Widget build(BuildContext context) {
    return Container(
      color: flightEventStyleOf(event.type).color().withValues(alpha: 0.55),
    );
  }
}

/// Marker dot for one flight event, dimmed while still ahead of the
/// playhead.
///
/// Leaf consumer on the playhead only — the parent tooltip/button (built once
/// per loaded flight) never rebuilds at the ticker rate.
class _EventDot extends ConsumerWidget {
  final FlightEvent event;

  const _EventDot({required this.event});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final positionMs = ref.watch(replayProvider.select((s) => s.positionMs));
    return FlightEventDot(
      type: event.type,
      dimmed: positionMs < event.positionMs,
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
  final bool enabled;

  const _SpeedMenu({
    required this.speed,
    required this.onSelect,
    this.enabled = true,
  });

  static String _label(double s) =>
      s < 1 ? '${s.toStringAsFixed(1)}×' : '${s.toInt()}×';

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<double>(
      initialValue: speed,
      enabled: enabled,
      tooltip: enabled ? 'Playback speed' : 'Loading flight…',
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
