import 'package:flutter/material.dart';

import '../../theme/app_colors.dart';
import 'time_series_chart.dart';

/// Horizontal and total body acceleration over time (m/s²).
class AccelerationChartWidget extends StatelessWidget {
  const AccelerationChartWidget({super.key});

  @override
  Widget build(BuildContext context) {
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
  }
}
