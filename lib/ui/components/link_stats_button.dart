import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:trycatch/core/packet_rate_tracker.dart';

import '../../core/channel_health.dart';
import '../../state/channel_health_provider.dart';
import '../../state/telemetry_provider.dart';
import '../../theme/app_colors.dart';
import '../screens/router.dart';

/// Combined link-stats button for the top bar: packet rate + unknown
/// bytes/s in one fixed-width slot.
///
/// Replaces the separate packet-rate readout and channel-health pill. The
/// whole button takes on the channel-verdict color (tinted wash, colored
/// border, tinted text); tapping opens the Channel health screen. Fixed
/// width so live value changes never shift siblings. The two values share
/// the width equally with a fixed centered separator, so the divider never
/// wanders as the numbers change length.
///
/// Deliberately connection-agnostic: both halves report live data alone —
/// packet rate decays to "N s ago" when no packet arrived within the last
/// 2 s (the [PacketRateTracker] window), and the unknown rate holds its
/// last value through silence. A disconnected port therefore reads as
/// decaying numbers, never as a blank OFFLINE.
///
/// The color is the worse of link liveness and congestion
/// (`max(packet severity, congestion severity)`): a link that stopped
/// delivering packets reads red no matter how quiet the frequency is.
/// Pure helper [linkStateColor] pins the mapping; unit-tested.
class LinkStatsButton extends ConsumerStatefulWidget {
  static const double width = 188;

  const LinkStatsButton({super.key});

  @override
  ConsumerState<LinkStatsButton> createState() => _LinkStatsButtonState();
}

/// Pill color for the top-bar link button: the worse of link liveness and
/// congestion. No packets within the liveness window reads red no matter
/// how quiet the frequency is; otherwise the congestion verdict color.
/// Neutral before any data ever arrived.
///
/// Pure in ([unmatchedBps], [packetsLive], [hasData]); unit-tested.
Color linkStateColor({
  required double unmatchedBps,
  required bool packetsLive,
  required bool hasData,
}) {
  if (!hasData) return AppColors.mutedForeground;
  if (!packetsLive) return AppColors.destructive;
  return switch (verdictFor(unmatchedBps)) {
    ChannelVerdict.clear => AppColors.success,
    ChannelVerdict.activity => AppColors.warning,
    ChannelVerdict.interference => AppColors.destructive,
  };
}

class _LinkStatsButtonState extends ConsumerState<LinkStatsButton> {
  final PacketRateTracker _rate = PacketRateTracker();
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
    // Shared channel history — survives rebuilds (see channel_health_provider).
    ref.watch(channelHealthProvider);
    final channel = ref.read(channelHealthProvider.notifier).tracker;

    final unmatched = channel.latest?.unmatchedBps ?? 0.0;
    final hasData =
        channel.latest != null || _rate.timeSinceLastPacket() != null;
    final Color stateColor = linkStateColor(
      unmatchedBps: unmatched,
      packetsLive: !_rate.isTimedOut(),
      hasData: hasData,
    );
    final ratePart = linkRateLabel(_rate);
    final channelPart =
        channel.latest == null ? '··· B/s' : formatBps(unmatched);
    const tip =
        'Packet rate and unknown traffic on this frequency (ours vs unknown) '
        '— live even while disconnected. Open Channel health.';
    final textColor = hasData
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
                  color: stateColor.withValues(alpha: hasData ? 0.12 : 0.06),
                  borderRadius: BorderRadius.circular(AppDimens.radiusSmall),
                  border: Border.all(
                    color: stateColor.withValues(alpha: hasData ? 0.5 : 0.3),
                  ),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  mainAxisSize: MainAxisSize.max,
                  children: [
                    // Two equal halves keep the separator dead-center no
                    // matter how the value lengths change.
                    Expanded(
                      child: ExcludeSemantics(
                        child: Text(
                          ratePart,
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
                          channelPart,
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
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
