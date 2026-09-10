import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/telemetry_store.dart';
import '../../theme/app_colors.dart';
import '../components/centered_stat.dart';
import '../components/waiting_for_data.dart';
import './shared/time_series_chart.dart';

/// Horizontal, vertical (dashed) and total speed over time (m/s).
/// Very short tiles show the live total instead of the graph.
class VelocityChartTile extends ConsumerWidget {
  const VelocityChartTile({super.key});

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
            value: '${latest.speedTotal.toStringAsFixed(1)} m/s',
            valueColor: AppColors.seriesVelocity,
          ),
        );
      }
      return TimeSeriesChart(
        config: TimeSeriesConfig(
          unit: 'm/s',
          series: [
            SeriesSpec(
              label: 'Horizontal',
              color: AppColors.seriesVelocity,
              value: (f) => f.speedHorizontal,
            ),
            SeriesSpec(
              label: 'Vertical',
              color: AppColors.seriesVelocityVertical,
              value: (f) => f.speedVertical,
              dashed: true,
            ),
            SeriesSpec(
              label: 'Total',
              color: AppColors.foreground,
              value: (f) => f.speedTotal,
            ),
          ],
        ),
      );
    });
  }
}
