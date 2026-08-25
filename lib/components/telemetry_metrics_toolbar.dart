import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:trycatch/src/telemetry/packet_rate_tracker.dart';
import 'package:trycatch/src/telemetry/telemetry_provider.dart';

/// Real-time throughput (packets/sec) or elapsed inactivity timeout display.
class TelemetryMetricsToolbar extends ConsumerStatefulWidget {
  const TelemetryMetricsToolbar({super.key});

  @override
  ConsumerState<TelemetryMetricsToolbar> createState() =>
      _TelemetryMetricsToolbarState();
}

class _TelemetryMetricsToolbarState
    extends ConsumerState<TelemetryMetricsToolbar> {
  final PacketRateTracker _rateTracker = PacketRateTracker();
  Timer? _uiRefreshTimer;

  @override
  void initState() {
    super.initState();

    // Refresh UI at 10 Hz (every 100ms)
    _uiRefreshTimer = Timer.periodic(const Duration(milliseconds: 100), (_) {
      if (mounted) {
        setState(() => _rateTracker.sample());
      }
    });
  }

  @override
  void dispose() {
    _uiRefreshTimer?.cancel();
    super.dispose();
  }

  String _formatTimeSinceLastPacket(Duration? duration) {
    if (duration == null) return 'No packets yet';

    final totalSeconds = duration.inMilliseconds / 1000.0;

    if (totalSeconds < 1.0) {
      return '${duration.inMilliseconds}ms ago';
    } else if (totalSeconds < 60.0) {
      return '${totalSeconds.toStringAsFixed(1)}s ago';
    } else {
      final mins = duration.inMinutes;
      final secs = duration.inSeconds % 60;

      return '${mins}m ${secs}s ago';
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(telemetryStreamProvider, (_, next) {
      next.whenData((_) => _rateTracker.recordPacket());
    });

    final isTimedOut = _rateTracker.isTimedOut();

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        isTimedOut
            ? _formatTimeSinceLastPacket(_rateTracker.timeSinceLastPacket())
            : '${_rateTracker.getAveragePacketsPerSecond().toStringAsFixed(1)} pkt/s',
        style: const TextStyle(
          fontFamily: 'Monospace',
          fontSize: 15,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}
