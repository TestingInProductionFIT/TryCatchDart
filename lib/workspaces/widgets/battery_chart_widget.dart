import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:serial/serial.dart';

import '../../src/telemetry/telemetry_store.dart';
import '../../theme/app_colors.dart';
import '../../theme/widgets/status_pill.dart';
import 'time_series_chart.dart';

/// Battery voltage: live readout with state-of-charge pill plus the
/// voltage-over-time chart.
class BatteryChartWidget extends ConsumerWidget {
  const BatteryChartWidget({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(telemetryStoreProvider);
    final latest = state.latest;
    final voltage = latest?.batteryVoltage;
    final dischargeRate = _dischargeRateMvPerMin(state);

    // 2S LiPo reference points.
    final (pillColor, pillLabel) = voltage == null
        ? (AppColors.mutedForeground, 'no data')
        : voltage >= 7.9
            ? (AppColors.success, 'charged')
            : voltage >= 7.5
                ? (AppColors.warning, 'under load')
                : (AppColors.destructive, 'low — land soon');

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: Row(
            children: [
              Text(
                voltage == null
                    ? '—'
                    : '${voltage.toStringAsFixed(2)} V',
                style: AppText.mono.copyWith(
                  fontSize: 18,
                  fontWeight: FontWeight.w800,
                  fontFeatures: const [FontFeature.tabularFigures()],
                  color: voltage == null
                      ? AppColors.mutedForeground
                      : AppColors.foreground,
                ),
              ),
              const Spacer(),
              StatusPill(label: pillLabel, color: pillColor),
            ],
          ),
        ),
        if (dischargeRate != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
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
        Expanded(
          child: TimeSeriesChart(
            config: TimeSeriesConfig(
              unit: 'V',
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
