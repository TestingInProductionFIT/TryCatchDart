import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../state/telemetry_store.dart';
import '../../theme/app_colors.dart';
import '../components/centered_stat.dart';
import '../components/waiting_for_data.dart';
import './shared/time_series_chart.dart';

/// Barometric altitude over time (m AGL) — the headline series, team pink.
/// Very short tiles show the live number instead of the graph.
class AltitudeChartTile extends ConsumerWidget {
  const AltitudeChartTile({super.key});

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
            value: formatAltitudeM(latest.baroAltitude),
            valueColor: AppColors.seriesAltitude,
          ),
        );
      }
      return TimeSeriesChart(
        config: TimeSeriesConfig(
          unit: 'm',
          // Single line — no legend needed.
          showLegend: false,
          series: [
            SeriesSpec(
              label: 'Barometric altitude',
              color: AppColors.seriesAltitude,
              value: (f) => f.baroAltitude,
            ),
          ],
        ),
      );
    });
  }
}
