import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/telemetry_store.dart';
import '../../theme/app_colors.dart';
import '../components/centered_stat.dart';
import '../components/waiting_for_data.dart';
import './shared/time_series_chart.dart';

/// Horizontal and total body acceleration over time (m/s²).
/// Very short tiles show the live total instead of the graph.
class AccelerationChartTile extends ConsumerWidget {
  const AccelerationChartTile({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final latest = ref.watch(telemetryStoreProvider).latest;
    return LayoutBuilder(builder: (context, constraints) {
      if (constraints.maxHeight.isFinite &&
          constraints.maxHeight < 90) {
        if (latest == null) {
          return const Center(child: WaitingForData(compact: true));
        }
        return Center(
          child: CenteredValue(
            value: '${latest.accelTotal.toStringAsFixed(1)} m/s²',
            valueColor: AppColors.seriesAccel,
          ),
        );
      }
      return TimeSeriesChart(
        config: TimeSeriesConfig(
          unit: 'm/s²',
          series: [
            SeriesSpec(
              label: 'Horizontal',
              color: AppColors.seriesAccel,
              value: (f) => f.accelHorizontal,
            ),
            SeriesSpec(
              label: 'Total',
              color: AppColors.foreground,
              value: (f) => f.accelTotal,
            ),
          ],
        ),
      );
    });
  }
}
