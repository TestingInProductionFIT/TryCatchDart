import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:trycatch/src/telemetry/packet_rate_tracker.dart';
import 'package:trycatch/src/telemetry/telemetry_provider.dart';

import '../theme/app_colors.dart';

/// Fixed-width packet-rate readout for the PACKETS cell: live pink "X pkt/s"
/// value while data flows, muted "last Ns ago" through dropouts.
class PacketRateIndicator extends ConsumerStatefulWidget {
  static const double width = 128;

  const PacketRateIndicator({super.key});

  @override
  ConsumerState<PacketRateIndicator> createState() =>
      _PacketRateIndicatorState();
}

class _PacketRateIndicatorState extends ConsumerState<PacketRateIndicator> {
  final PacketRateTracker _tracker = PacketRateTracker();
  Timer? _uiTimer;

  @override
  void initState() {
    super.initState();
    _uiTimer = Timer.periodic(const Duration(milliseconds: 250), (_) {
      if (mounted) setState(() => _tracker.sample());
    });
  }

  @override
  void dispose() {
    _uiTimer?.cancel();
    super.dispose();
  }

  String _ago() {
    final d = _tracker.timeSinceLastPacket();
    if (d == null) return 'no data yet';
    final s = d.inMilliseconds / 1000.0;
    if (s < 1.0) return '${d.inMilliseconds} ms ago';
    if (s < 60) return '${s.toStringAsFixed(1)} s ago';
    return '${d.inMinutes}m ${d.inSeconds % 60}s ago';
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(telemetryStreamProvider, (_, next) {
      next.whenData((_) => _tracker.recordPacket());
    });

    final timedOut = _tracker.isTimedOut();
    final label = timedOut
        ? _ago()
        : '${_tracker.getAveragePacketsPerSecond().toStringAsFixed(1)} pkt/s';

    return SizedBox(
      width: PacketRateIndicator.width,
      height: 32,
      child: Row(
        children: [
          Container(
            width: 7,
            height: 7,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: timedOut ? AppColors.faint : AppColors.pink,
              boxShadow: timedOut
                  ? null
                  : const [BoxShadow(color: Color(0x40FF00A1), blurRadius: 6)],
            ),
          ),
          const SizedBox(width: 7),
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppText.monoValue.copyWith(
                fontSize: 12.5,
                color:
                    timedOut ? AppColors.mutedForeground : AppColors.foreground,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
