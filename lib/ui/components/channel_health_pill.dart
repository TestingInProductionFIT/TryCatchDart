import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/channel_health.dart';
import '../../state/telemetry_provider.dart';
import '../../theme/app_colors.dart';
import '../screens/router.dart';
import './status_pill.dart';

/// Live channel-health pill for the top bar: dot + unknown bytes/s.
///
/// Green while the frequency is clear, amber on unknown activity, pulsing red
/// on interference — the top-bar alert for a degrading channel. Tapping it
/// opens the Channel health screen.
///
/// Always occupies the same 96px slot (muted OFFLINE while disconnected) so
/// the bar never shifts when the link comes up. Hidden while replaying.
class ChannelHealthPill extends ConsumerStatefulWidget {
  const ChannelHealthPill({super.key});

  @override
  ConsumerState<ChannelHealthPill> createState() => _ChannelHealthPillState();
}

class _ChannelHealthPillState extends ConsumerState<ChannelHealthPill> {
  final ChannelHealthTracker _tracker = ChannelHealthTracker();

  @override
  Widget build(BuildContext context) {
    ref.listen(linkStatsStreamProvider, (_, next) {
      next.whenData((stats) {
        _tracker.addSnapshot(stats);
        if (mounted) setState(() {});
      });
    });
    final connected =
        ref.watch(serialStatusProvider).value?.isConnected ?? false;

    final (label, color, hint, pulsing) = !connected
        ? (
            'OFFLINE',
            AppColors.mutedForeground,
            'Not connected — connect a port to scan the frequency. '
                'Open Channel health.',
            false,
          )
        : switch (verdictFor(_tracker.latest?.unmatchedBps ?? 0.0)) {
            ChannelVerdict.clear => (
              _tracker.latest == null
                  ? '···'
                  : formatBps(_tracker.latest!.unmatchedBps),
              AppColors.success,
              'Channel clear — quiet frequency. Open Channel health.',
              false,
            ),
            ChannelVerdict.activity => (
              formatBps(_tracker.latest!.unmatchedBps),
              AppColors.warning,
              'Unknown signals on this frequency — watch it before launch. '
                  'Open Channel health.',
              false,
            ),
            ChannelVerdict.interference => (
              formatBps(_tracker.latest!.unmatchedBps),
              AppColors.destructive,
              'Interference — unknown transmitter is active here. '
                  'Open Channel health.',
              true,
            ),
          };

    return SizedBox(
      width: 96,
      child: Center(
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          child: GestureDetector(
            onTap: () =>
                ref.read(appRouterProvider.notifier).go(AppScreen.monitor),
            child: Tooltip(
              message: hint,
              mouseCursor: SystemMouseCursors.click,
              child: StatusPill(
                label: label,
                color: color,
                pulsing: pulsing,
                height: 32,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
