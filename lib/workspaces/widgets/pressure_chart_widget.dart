import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../flights/replay_controller.dart';
import '../../src/atmosphere/pressure.dart';
import '../../src/telemetry/telemetry_store.dart';
import '../../theme/app_colors.dart';
import 'time_series_chart.dart';

/// Static air pressure over time (hPa).
///
/// The wire format carries barometric altitude, not raw pressure, so this
/// inverts the ISA model anchored at the selected launch site's MSL
/// altitude (sea-level reference when no site is selected) — the same model
/// the flight software uses in the forward direction.
class PressureChartWidget extends ConsumerWidget {
  const PressureChartWidget({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final siteMsl = ref.watch(effectiveLaunchSiteProvider)?.altitudeMsl ?? 0;
    final latest = ref.watch(telemetryStoreProvider).latest;
    final hpa = latest == null
        ? null
        : pressurePaFromBaro(latest.baroAltitude, siteMslM: siteMsl) / 100;

    double value(double baroAlt) =>
        pressurePaFromBaro(baroAlt, siteMslM: siteMsl) / 100;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: Row(
            children: [
              Text(
                hpa == null ? '—' : '${hpa.toStringAsFixed(1)} hPa',
                style: AppText.mono.copyWith(
                  fontSize: 18,
                  fontWeight: FontWeight.w800,
                  fontFeatures: const [FontFeature.tabularFigures()],
                  color: hpa == null
                      ? AppColors.mutedForeground
                      : AppColors.foreground,
                ),
              ),
              const Spacer(),
              Text(
                siteMsl > 0
                    ? 'derived · ref ${siteMsl.toStringAsFixed(0)} m MSL'
                    : 'derived · sea-level ref',
                style: AppText.microLabel.copyWith(fontSize: 8.5),
              ),
            ],
          ),
        ),
        Expanded(
          child: TimeSeriesChart(
            config: TimeSeriesConfig(
              unit: 'hPa',
              series: [
                SeriesSpec(
                  label: 'Pressure',
                  color: AppColors.seriesPressure,
                  value: (f) => value(f.baroAltitude),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
