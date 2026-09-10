import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:trycatch/core/packet_rate_tracker.dart';

import '../../core/channel_health.dart';
import '../../state/telemetry_provider.dart';
import '../../theme/app_colors.dart';
import '../screens/router.dart';

/// Combined link-stats button for the top bar: packet rate + unknown
/// bytes/s in one fixed-width slot.
///
/// Replaces the separate packet-rate readout and channel-health pill. The
/// whole button takes on the channel-verdict color (tinted wash, colored
/// border, tinted text — muted while offline); tapping opens the Channel
/// health screen. Fixed width so live value changes never shift siblings.
/// The two values share the width equally with a fixed centered separator,
/// so the divider never wanders as the numbers change length.
class LinkStatsButton extends ConsumerStatefulWidget {
  static const double width = 188;

  const LinkStatsButton({super.key});

  @override
  ConsumerState<LinkStatsButton> createState() => _LinkStatsButtonState();
}

class _LinkStatsButtonState extends ConsumerState<LinkStatsButton> {
  final PacketRateTracker _rate = PacketRateTracker();
  final ChannelHealthTracker _channel = ChannelHealthTracker();
  Timer? _uiTimer;

  @override
  void initState() {
    super.initState();
    _uiTimer = Timer.periodic(const Duration(milliseconds: 250), (_) {
      if (mounted) setState(() => _rate.sample());
    });
  }

  @override
  void dispose() {
    _uiTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(telemetryStreamProvider, (_, next) {
      next.whenData((_) => _rate.recordPacket());
    });
    ref.listen(linkStatsStreamProvider, (_, next) {
      next.whenData((stats) {
        _channel.addSnapshot(stats);
        if (mounted) setState(() {});
      });
    });
    final connected =
        ref.watch(serialStatusProvider).value?.isConnected ?? false;

    final Color stateColor;
    final String? ratePart;
    final String? channelPart;
    final String tip;
    if (!connected) {
      stateColor = AppColors.mutedForeground;
      ratePart = null;
      channelPart = null;
      tip =
          'Not connected — connect a port to scan the frequency. '
          'Open Channel health.';
    } else {
      final unmatched = _channel.latest?.unmatchedBps ?? 0.0;
      stateColor = switch (verdictFor(unmatched)) {
        ChannelVerdict.clear => AppColors.success,
        ChannelVerdict.activity => AppColors.warning,
        ChannelVerdict.interference => AppColors.destructive,
      };
      ratePart = _rate.isTimedOut()
          ? 'idle'
          : '${_rate.getAveragePacketsPerSecond().toStringAsFixed(1)} pkt/s';
      channelPart = _channel.latest == null ? '··· B/s' : formatBps(unmatched);
      tip =
          'Packet rate and unknown traffic on this frequency (ours vs unknown). '
          'Open Channel health.';
    }
    final textColor = connected
        ? Color.lerp(stateColor, AppColors.foreground, 0.2)!
        : AppColors.mutedForeground;

    return SizedBox(
      width: LinkStatsButton.width,
      height: 32,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: Tooltip(
          message: tip,
          mouseCursor: SystemMouseCursors.click,
          child: Material(
            color: Colors.transparent,
            borderRadius: BorderRadius.circular(AppDimens.radiusSmall),
            child: InkWell(
              borderRadius: BorderRadius.circular(AppDimens.radiusSmall),
              mouseCursor: SystemMouseCursors.click,
              onTap: () =>
                  ref.read(appRouterProvider.notifier).go(AppScreen.monitor),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 10),
                decoration: BoxDecoration(
                  color: stateColor.withValues(alpha: connected ? 0.12 : 0.06),
                  borderRadius: BorderRadius.circular(AppDimens.radiusSmall),
                  border: Border.all(
                    color: stateColor.withValues(alpha: connected ? 0.5 : 0.3),
                  ),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  mainAxisSize: MainAxisSize.max,
                  children: [
                    if (!connected)
                      Flexible(
                        child: ExcludeSemantics(
                          child: Text(
                            'OFFLINE',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            textAlign: TextAlign.center,
                            style: AppText.mono.copyWith(
                              fontSize: 11.5,
                              fontWeight: FontWeight.w700,
                              color: textColor,
                              fontFeatures: const [
                                FontFeature.tabularFigures(),
                              ],
                            ),
                          ),
                        ),
                      )
                    else ...[
                      // Two equal halves keep the separator dead-center no
                      // matter how the value lengths change.
                      Expanded(
                        child: ExcludeSemantics(
                          child: Text(
                            ratePart!,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            textAlign: TextAlign.right,
                            style: AppText.mono.copyWith(
                              fontSize: 11.5,
                              fontWeight: FontWeight.w700,
                              color: textColor,
                              fontFeatures: const [
                                FontFeature.tabularFigures(),
                              ],
                            ),
                          ),
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 6),
                        child: Container(
                          width: 1,
                          height: 14,
                          color: textColor.withValues(alpha: 0.5),
                        ),
                      ),
                      Expanded(
                        child: ExcludeSemantics(
                          child: Text(
                            channelPart!,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            textAlign: TextAlign.left,
                            style: AppText.mono.copyWith(
                              fontSize: 11.5,
                              fontWeight: FontWeight.w700,
                              color: textColor,
                              fontFeatures: const [
                                FontFeature.tabularFigures(),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
