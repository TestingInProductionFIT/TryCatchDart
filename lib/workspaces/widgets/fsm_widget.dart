import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:serial/serial.dart';
import 'package:trycatch/src/collections/ring_buffer.dart';

import '../../src/telemetry/telemetry_store.dart';
import '../../theme/app_colors.dart';

/// Flight-software state machine view: the current state large on top with
/// the time in it, and the ordered state pipeline filling the rest.
///
/// The layout is responsive — it fills whatever the tile gives it instead of
/// scaling a fixed design; the state name scales down via [FittedBox] and the
/// pipeline chips wrap.
class FsmWidget extends ConsumerWidget {
  const FsmWidget({super.key});

  /// Displayed pipeline order (wire ids).
  static const List<FsmState> _pipeline = [
    FsmState.idle,
    FsmState.armed,
    FsmState.boost,
    FsmState.coast,
    FsmState.apogee,
    FsmState.drogue,
    FsmState.main,
    FsmState.landed,
  ];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(telemetryStoreProvider);
    final latest = state.latest;

    if (latest == null) {
      return const _NoData();
    }

    final current = latest.fsmState;
    final color = AppColors.fsmColor(current);
    final timeInState = _timeInState(state.history);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Container(
                width: 12,
                height: 12,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: color,
                  boxShadow: [
                    BoxShadow(
                      color: color.withValues(alpha: 0.4),
                      blurRadius: 8,
                      spreadRadius: 1,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: Text(
                    current.label.toUpperCase(),
                    style: AppText.mono.copyWith(
                      fontSize: 30,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 0.5,
                      color: color,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Text(
                timeInState,
                style: AppText.mono.copyWith(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: AppColors.mutedForeground,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Expanded(
            child: Align(
              alignment: Alignment.topLeft,
              child: Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final s in _pipeline)
                    _StateChip(
                      state: s,
                      current: s == current,
                      passed: _pipeline.indexOf(s) < _pipeline.indexOf(current),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// How long the rocket has been in the current state, from history.
  String _timeInState(RingBuffer<TelemetryFrame> history) {
    if (history.isEmpty) return '';
    final current = history[0].fsmState; // newest frame
    var since = history.getChronological(history.length - 1).receivedAtMs;
    for (final frame in history.newestFirst()) {
      if (frame.fsmState != current) {
        since = frame.receivedAtMs;
        break;
      }
    }
    final seconds = (history[0].receivedAtMs - since) / 1000;
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
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
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
    );
  }
}

class _NoData extends StatelessWidget {
  const _NoData();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Text(
        'No telemetry',
        style: TextStyle(fontSize: 12, color: AppColors.mutedForeground),
      ),
    );
  }
}
