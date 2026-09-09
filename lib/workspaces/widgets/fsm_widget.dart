import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:serial/serial.dart';

import '../../src/telemetry/telemetry_store.dart';
import '../../theme/app_colors.dart';
import '../../theme/widgets/waiting_for_data.dart';

/// Flight-software state machine view.
///
/// The current state fills the tile — big, centred both ways, time in state
/// under it — with the pipeline grid + progress bar pinned to the bottom.
///
/// A 1 s ticker keeps the time-in-state counting while the link is silent
/// (packet times alone would freeze it the moment telemetry stops).
class FsmWidget extends ConsumerStatefulWidget {
  const FsmWidget({super.key});

  @override
  ConsumerState<FsmWidget> createState() => _FsmWidgetState();
}

class _FsmWidgetState extends ConsumerState<FsmWidget> {
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  /// Displayed pipeline order (flight order — debug states are
  /// off-pipeline branches and show with an empty progress bar, like
  /// unknown).
  static const List<FsmState> _pipeline = [
    FsmState.idle,
    FsmState.armed,
    FsmState.ascent,
    FsmState.apogee,
    FsmState.parachute,
    FsmState.landed,
  ];

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(telemetryStoreProvider);
    final latest = state.latest;

    if (latest == null) {
      return Center(child: WaitingForData());
    }

    final current = latest.fsmState;
    final color = AppColors.fsmColor(current);
    final timeInState = _timeInState(state);
    final currentIndex = _pipeline.indexOf(current);

    return LayoutBuilder(builder: (context, constraints) {
      // Chips tile the available width and size to their content — the grid
      // takes whatever it needs, the big state name gets everything else.
      final columns = (constraints.maxWidth / 108).floor().clamp(2, 4);
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // The current state fills everything the grid doesn't need,
          // centred both ways.
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Flexible(
                  child: FittedBox(
                    fit: BoxFit.contain,
                    child: Text(
                      current.label.toUpperCase(),
                      textAlign: TextAlign.center,
                      style: AppText.mono.copyWith(
                        fontSize: 40,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 0.5,
                        color: color,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  timeInState,
                  textAlign: TextAlign.center,
                  style: AppText.mono.copyWith(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: AppColors.mutedForeground,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: _ProgressBar(
              progress: currentIndex < 0
                  ? 0
                  : (currentIndex + 1) / _pipeline.length,
              color: color,
            ),
          ),
          // Pipeline grid pinned to the bottom, sized to its content.
          GridView.count(
            crossAxisCount: columns,
            mainAxisSpacing: 6,
            crossAxisSpacing: 6,
            childAspectRatio: 3.4,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            padding: EdgeInsets.zero,
            children: [
              for (final s in _pipeline)
                _StateChip(
                  state: s,
                  current: s == current,
                  passed: currentIndex >= 0 &&
                      _pipeline.indexOf(s) < currentIndex,
                ),
            ],
          ),
        ],
      );
    });
  }

  /// How long the rocket has been in the current state, from history. While
  /// the live link is silent the wall clock keeps it ticking past the last
  /// frame; during a replay the playhead rules instead (the wall clock can
  /// be hours off the recording).
  String _timeInState(TelemetryState state) {
    final history = state.history;
    if (history.isEmpty) return '';
    final latest = history[0];
    final current = latest.fsmState; // newest frame
    var since = history.getChronological(history.length - 1).receivedAtMs;
    for (final frame in history.newestFirst()) {
      if (frame.fsmState != current) {
        since = frame.receivedAtMs;
        break;
      }
    }
    var endMs = latest.receivedAtMs;
    if (!state.replaying) {
      final nowMs = DateTime.now().millisecondsSinceEpoch;
      if (nowMs - latest.receivedAtMs > TelemetryStore.drStaleMs) {
        endMs = nowMs;
      }
    }
    final seconds = (endMs - since) / 1000;
    final m = seconds ~/ 60;
    final s = (seconds % 60).toStringAsFixed(0).padLeft(2, '0');
    return '${m > 0 ? '$m m ' : ''}$s s in state';
  }
}

class _StateChip extends StatelessWidget {
  final FsmState state;
  final bool current;
  final bool passed;

  const _StateChip({required this.state, required this.current, required this.passed});

  @override
  Widget build(BuildContext context) {
    final color = AppColors.fsmColor(state);
    return Container(
      alignment: Alignment.center,
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
      decoration: BoxDecoration(
        color: current
            ? color
            : passed
                ? AppColors.muted
                : AppColors.card,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(
          color: current ? color : AppColors.border,
          width: current ? 1.2 : 1,
        ),
      ),
      child: FittedBox(
        fit: BoxFit.scaleDown,
        child: Text(
          state.label.toUpperCase(),
          style: AppText.mono.copyWith(
            fontSize: 10,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.8,
            color: current
                ? Colors.white
                : passed
                    ? AppColors.mutedForeground
                    : AppColors.faint,
          ),
        ),
      ),
    );
  }
}

/// Thin flight-progress bar under the pipeline: fraction of the ordered
/// pipeline reached so far.
class _ProgressBar extends StatelessWidget {
  final double progress;
  final Color color;

  const _ProgressBar({required this.progress, required this.color});

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, constraints) {
      return Container(
        height: 5,
        decoration: BoxDecoration(
          color: AppColors.muted,
          borderRadius: BorderRadius.circular(3),
        ),
        alignment: Alignment.centerLeft,
        child: Container(
          width: (constraints.maxWidth * progress.clamp(0.0, 1.0)),
          height: 5,
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(3),
          ),
        ),
      );
    });
  }
}
