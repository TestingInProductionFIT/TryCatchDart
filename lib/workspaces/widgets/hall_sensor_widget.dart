import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../src/telemetry/telemetry_store.dart';
import '../../theme/app_colors.dart';
import '../../theme/widgets/status_pill.dart';
import 'time_series_chart.dart';

/// Breakaway-wire hall sensor: raw dimensionless readout (typically 2–3k),
/// intact/broken badge against a configurable threshold, and the shared
/// scrolling time-series chart.
class HallSensorWidget extends ConsumerWidget {
  /// Raw value at or above which the wire counts as broken.
  static const double triggeredThreshold = 2700;

  const HallSensorWidget({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final latest = ref.watch(telemetryStoreProvider).latest;

    final raw = latest?.hallRaw ?? 0;
    final triggered = raw >= triggeredThreshold;
    final color = triggered ? AppColors.destructive : AppColors.success;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Text(
              latest == null ? '—' : '$raw',
              style: AppText.mono.copyWith(
                fontSize: 20,
                fontWeight: FontWeight.w800,
                fontFeatures: const [FontFeature.tabularFigures()],
                color: latest == null ? AppColors.mutedForeground : color,
              ),
            ),
            const Spacer(),
            StatusPill(
              label: latest == null
                  ? 'no data'
                  : triggered
                      ? 'wire broken'
                      : 'wire intact',
              color: latest == null ? AppColors.mutedForeground : color,
            ),
          ],
        ),
        const SizedBox(height: 6),
        Expanded(
          child: TimeSeriesChart(
            config: TimeSeriesConfig(
              unit: '',
              showLegend: false,
              series: [
                SeriesSpec(
                  label: 'Hall',
                  color: color,
                  value: (f) => f.hallRaw.toDouble(),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
