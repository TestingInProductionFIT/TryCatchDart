import 'package:flutter/material.dart';

import '../../theme/app_colors.dart';
import 'time_series_chart.dart';

/// Horizontal, vertical (dashed) and total speed over time (m/s).
class VelocityChartWidget extends StatelessWidget {
  const VelocityChartWidget({super.key});

  @override
  Widget build(BuildContext context) {
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
  }
}
