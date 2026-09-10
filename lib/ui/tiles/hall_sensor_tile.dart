import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/telemetry_store.dart';
import '../../theme/app_colors.dart';
import '../components/centered_stat.dart';
import '../components/waiting_for_data.dart';
import './shared/time_series_chart.dart';

/// Breakaway-wire hall sensor over time: no raw-number header — the line
/// color carries the state (green intact, red broken at [triggeredThreshold]).
/// Very short tiles drop the graph and show just the number.
class HallSensorTile extends ConsumerWidget {
  /// Raw value at or above which the wire counts as broken.
  static const double triggeredThreshold = 2700;

  const HallSensorTile({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final latest = ref.watch(telemetryStoreProvider).latest;

    final raw = latest?.hallRaw ?? 0;
    final triggered = raw >= triggeredThreshold;
    final color = triggered ? AppColors.destructive : AppColors.success;

    return LayoutBuilder(builder: (context, constraints) {
      if (constraints.maxHeight.isFinite &&
          constraints.maxHeight < 110) {
        if (latest == null) {
          return const Center(child: WaitingForData(compact: true));
        }
        return Center(
          child: CenteredValue(
            value: '$raw',
            valueColor: color,
          ),
        );
      }
      return TimeSeriesChart(
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
      );
    });
  }
}
