import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:serial/serial.dart';

import '../../state/telemetry_store.dart';
import '../../theme/app_colors.dart';
import '../components/centered_stat.dart';
import '../components/waiting_for_data.dart';
import './shared/time_series_chart.dart';

/// Battery voltage over time, plus the 1-minute discharge average.
/// No big numeric header — the chart and the trend line carry the state.
class BatteryChartTile extends ConsumerWidget {
  const BatteryChartTile({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(telemetryStoreProvider);
    final dischargeRate = _dischargeRateMvPerMin(state);

    return LayoutBuilder(
      builder: (context, constraints) {
        // Very short tiles drop the graph and show the live voltage.
        if (constraints.maxHeight.isFinite &&
            constraints.maxHeight < 110) {
          final latest = state.latest;
          if (latest == null) {
            return const Center(child: WaitingForData(compact: true));
          }
          return Center(
            child: CenteredValue(
              value: '${latest.batteryVoltage.toStringAsFixed(2)} V',
              valueColor: AppColors.seriesBattery,
            ),
          );
        }
        // The discharge average is a nice-to-have: short tiles keep the
        // chart on its own.
        final showRate = dischargeRate != null && constraints.maxHeight >= 170;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (showRate)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                // Display-only average — excluded from semantics.
                child: ExcludeSemantics(
                  child: Text(
                    // Negative when the battery is draining.
                    '${dischargeRate >= 0 ? '+' : '−'}'
                    '${dischargeRate.abs().toStringAsFixed(0)} mV/min avg · last min',
                    style: AppText.mono.copyWith(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      fontFeatures: const [FontFeature.tabularFigures()],
                      color: AppColors.mutedForeground,
                    ),
                  ),
                ),
              ),
            Expanded(
              child: TimeSeriesChart(
                config: TimeSeriesConfig(
                  unit: 'V',
                  // Single line — no legend needed.
                  showLegend: false,
                  series: [
                    SeriesSpec(
                      label: 'Battery',
                      color: AppColors.seriesBattery,
                      value: (f) => f.batteryVoltage,
                    ),
                  ],
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  /// Average discharge rate over the last 60 s, in mV/min (positive when the
  /// voltage is rising). `null` with less than a usable window of data.
  double? _dischargeRateMvPerMin(TelemetryState state) {
    final history = state.history;
    if (history.isEmpty) return null;
    final newest = history[0];
    final windowStartMs = newest.receivedAtMs - 60000;

    // Newest-first walk: the last frame inside the window is its oldest end.
    TelemetryFrame? oldest;
    for (var i = 0; i < history.length; i++) {
      final frame = history[i];
      if (frame.receivedAtMs < windowStartMs) break;
      oldest = frame;
    }
    if (oldest == null || identical(oldest, newest)) return null;

    final minutes = (newest.receivedAtMs - oldest.receivedAtMs) / 60000.0;
    if (minutes <= 0) return null;
    return (newest.batteryVoltage - oldest.batteryVoltage) * 1000 / minutes;
  }
}
