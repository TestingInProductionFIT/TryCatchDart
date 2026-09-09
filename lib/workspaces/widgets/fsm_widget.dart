import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:serial/serial.dart';

import '../../flights/replay_controller.dart';
import '../../src/telemetry/telemetry_provider.dart';
import '../../src/telemetry/telemetry_store.dart';
import '../../theme/app_colors.dart';
import '../../theme/widgets/waiting_for_data.dart';

/// Wire bytes for requesting an FSM state from the rocket.
///
/// Same framing as the control panel ([RocketCommands]): `0x54 0x43` magic
/// ('TC') + command byte + argument byte. The argument carries the target
/// [FsmState.id]; `0x07` is the made-up "set FSM state" command and must
/// match the flight software.
abstract final class FsmStateCommands {
  static const magicT = 0x54;
  static const magicC = 0x43;
  static const setStateCmd = 0x07;

  static List<int> bytesFor(FsmState state) =>
      [magicT, magicC, setStateCmd, state.id];
}

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
  Timer? _confirmTimer;
  FsmState? _pendingState;
  FsmState? _sentState;

  static const _confirmTimeout = Duration(seconds: 3);

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
    _confirmTimer?.cancel();
    super.dispose();
  }

  /// Two-click state request, mirroring the control panel: first tap arms
  /// the chip for 3 s, second tap sends the set-state bytes on the wire.
  void _onChipTap(FsmState state) {
    final connected =
        ref.read(serialStatusProvider).value?.isConnected ?? false;
    if (!connected) return;
    if (ref.read(replayProvider).isActive) return;

    if (_pendingState != state) {
      _confirmTimer?.cancel();
      setState(() {
        _pendingState = state;
        _sentState = null;
      });
      _confirmTimer = Timer(_confirmTimeout, () {
        if (mounted) setState(() => _pendingState = null);
      });
      return;
    }

    _confirmTimer?.cancel();
    final ok =
        ref.read(serialConfigProvider.notifier).sendBytes(FsmStateCommands.bytesFor(state));
    setState(() {
      _pendingState = null;
      _sentState = ok ? state : null;
    });
    if (ok) {
      Timer(const Duration(seconds: 1), () {
        if (mounted && _sentState == state) {
          setState(() => _sentState = null);
        }
      });
    }
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

  /// Bench states live off the flight pipeline — shown in their own row
  /// below the pipeline grid.
  static const List<FsmState> _debugStates = [
    FsmState.debugUnlocked,
    FsmState.debugLocked,
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
    final connected =
        ref.watch(serialStatusProvider).value?.isConnected ?? false;
    final replaying = ref.watch(replayProvider).isActive;
    final enabled = connected && !replaying;

    String tooltipFor(FsmState s) {
      if (!connected) return 'Connect first';
      if (_pendingState == s) return 'Tap again to send ${s.label} request';
      return 'Send ${s.label} request to rocket';
    }

    Widget chipFor(FsmState s, {required bool passed}) {
      final tileState = _sentState == s
          ? _ChipState.sent
          : _pendingState == s
              ? _ChipState.confirm
              : _ChipState.idle;
      return _StateChip(
        state: s,
        current: s == current,
        passed: passed,
        tileState: tileState,
        enabled: enabled,
        replaying: replaying,
        // No tooltips while replaying: the chips are plain state readouts.
        tooltip: replaying ? null : tooltipFor(s),
        onTap: () => _onChipTap(s),
      );
    }

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
          // Pipeline grid + debug row pinned to the bottom, sized to content.
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
                chipFor(
                  s,
                  passed: currentIndex >= 0 &&
                      _pipeline.indexOf(s) < currentIndex,
                ),
            ],
          ),
          const SizedBox(height: 6),
          GridView.count(
            crossAxisCount: 2,
            mainAxisSpacing: 6,
            crossAxisSpacing: 6,
            childAspectRatio: 3.4,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            padding: EdgeInsets.zero,
            children: [
              for (final s in _debugStates)
                chipFor(s, passed: false),
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

enum _ChipState { idle, confirm, sent }

class _StateChip extends StatelessWidget {
  final FsmState state;
  final bool current;
  final bool passed;
  final _ChipState tileState;
  final bool enabled;

  /// `true` while a replay is active: chips render as plain readouts —
  /// no tooltip, no disabled grey.
  final bool replaying;
  final String? tooltip;
  final VoidCallback onTap;

  const _StateChip({
    required this.state,
    required this.current,
    required this.passed,
    required this.tileState,
    required this.enabled,
    required this.replaying,
    required this.tooltip,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final color = AppColors.fsmColor(state);

    final Color background;
    final Color foreground;
    final Color border;
    final String label;
    switch (tileState) {
      case _ChipState.idle:
        background = current
            ? color
            : passed
                ? AppColors.muted
                : AppColors.card;
        foreground = current
            ? Colors.white
            : passed
                ? AppColors.mutedForeground
                : AppColors.faint;
        border = current ? color : AppColors.border;
        label = state.label.toUpperCase();
      case _ChipState.confirm:
        background = color;
        foreground = Colors.white;
        border = color;
        label = 'TAP AGAIN?';
      case _ChipState.sent:
        background = AppColors.success;
        foreground = Colors.white;
        border = AppColors.success;
        label = 'SENT';
    }

    final faded = !enabled && !replaying && tileState == _ChipState.idle;

    final content = MouseRegion(
      cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
      child: Material(
        color: faded ? background.withValues(alpha: 0.6) : background,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(6),
          side: BorderSide(
            color: tileState == _ChipState.idle ? border : Colors.transparent,
            width: current ? 1.2 : 1,
          ),
        ),
        child: InkWell(
          onTap: enabled ? onTap : null,
          borderRadius: BorderRadius.circular(6),
          child: Container(
            alignment: Alignment.center,
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(
                label,
                style: AppText.mono.copyWith(
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.8,
                  color: faded ? AppColors.faint : foreground,
                ),
              ),
            ),
          ),
        ),
      ),
    );

    // During replay the chips are inert readouts with no tooltip at all.
    final tip = tooltip;
    if (tip == null) return content;
    // Own semantics container per chip: like the control panel, these are
    // adjacent Tooltips inside GridViews — without the boundary they trip
    // the upstream Windows AXTree defect (flutter/flutter#182444).
    return Semantics(
      container: true,
      child: Tooltip(
        message: tip,
        waitDuration: const Duration(milliseconds: 500),
        child: content,
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
