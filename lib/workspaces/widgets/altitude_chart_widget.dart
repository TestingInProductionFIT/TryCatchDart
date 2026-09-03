import 'package:flutter/material.dart';

import '../../theme/app_colors.dart';
import 'time_series_chart.dart';

/// Barometric altitude over time (m AGL) — the headline series, team pink.
class AltitudeChartWidget extends StatelessWidget {
  const AltitudeChartWidget({super.key});

  @override
  Widget build(BuildContext context) {
    return TimeSeriesChart(
      config: TimeSeriesConfig(
        unit: 'm',
        series: [
          SeriesSpec(
            label: 'Barometric altitude',
            color: AppColors.seriesAltitude,
            value: (f) => f.baroAltitude,
          ),
        ],
      ),
    );
  }
}
