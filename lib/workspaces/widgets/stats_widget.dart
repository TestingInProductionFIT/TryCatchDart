import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../settings/launch_site_store.dart';
import '../../src/geo/geo.dart';
import '../../src/telemetry/telemetry_store.dart';
import '../../theme/app_colors.dart';

/// Numbers panel: two headline stats (max altitude, distance from the launch
/// site) on top, GPS and dead-reckoning position groups filling the rest.
///
/// The layout is responsive — it fills whatever the tile gives it instead of
/// scaling a fixed design; groups shrink via [FittedBox] when the tile is
/// small.
class StatsWidget extends ConsumerWidget {
  const StatsWidget({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(telemetryStoreProvider);
    final latest = state.latest;
    final site = ref.watch(currentLaunchSiteProvider);

    final gpsDistance = latest != null && site != null && latest.gpsHasFix
        ? haversineDistanceM(
            site.latitude, site.longitude, latest.latitude, latest.longitude)
        : null;

    final gpsLabel = latest == null
        ? 'GPS'
        : latest.gpsHas3dFix
            ? 'GPS · 3D FIX'
            : latest.gpsHasFix
                ? 'GPS · FIX'
                : 'GPS · NO FIX';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: _BigStat(
                label: 'Max alt',
                value: _metres(
                    state.history.isEmpty ? null : state.maxAltitude, 0),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: _BigStat(
                label: 'From site',
                value: gpsDistance == null
                    ? '—'
                    : gpsDistance >= 1000
                        ? '${(gpsDistance / 1000).toStringAsFixed(2)} km'
                        : '${gpsDistance.toStringAsFixed(0)} m',
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Expanded(
          child: _Group(
            label: gpsLabel,
            rows: [
              _kv('Lat', _coord(latest?.latitude)),
              _kv('Lon', _coord(latest?.longitude)),
              _kv('Alt', _metres(latest?.gpsAltitude)),
            ],
          ),
        ),
        const SizedBox(height: 8),
        Expanded(
          child: _Group(
            label: 'Dead reckoning',
            rows: [
              _kv('Lat', _coord(state.deadReckoning?.latitude)),
              _kv('Lon', _coord(state.deadReckoning?.longitude)),
              _kv('Alt', _metres(state.deadReckoning?.altitude)),
            ],
          ),
        ),
      ],
    );
  }

  static MapEntry<String, String> _kv(String k, String v) => MapEntry(k, v);

  static String _coord(double? deg) =>
      deg == null ? '—' : '${deg.toStringAsFixed(5)}°';

  static String _metres(double? m, [int? fallback]) => m == null
      ? (fallback == null ? '—' : '${fallback.toStringAsFixed(0)} m')
      : '${m.toStringAsFixed(m.abs() >= 100 ? 0 : 1)} m';
}

/// One tinted group card: mono label on top, key/value rows spanning the
/// full width below. Scales down as one unit when the tile is small.
class _Group extends StatelessWidget {
  final String label;
  final List<MapEntry<String, String>> rows;

  const _Group({required this.label, required this.rows});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: AppColors.muted,
        borderRadius: BorderRadius.circular(AppDimens.radiusSmall),
        border: Border.all(color: AppColors.border),
      ),
      alignment: Alignment.centerLeft,
      child: LayoutBuilder(builder: (context, constraints) {
        return FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerLeft,
          child: SizedBox(
            width: constraints.maxWidth,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label.toUpperCase(),
                  style:
                      AppText.microLabel.copyWith(fontSize: 9, letterSpacing: 1.2),
                ),
                const SizedBox(height: 3),
                for (final row in rows)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 2),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          row.key,
                          style: const TextStyle(
                              fontSize: 12, color: AppColors.mutedForeground),
                        ),
                        Text(
                          row.value,
                          style: AppText.mono.copyWith(
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                            fontFeatures: const [FontFeature.tabularFigures()],
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        );
      }),
    );
  }
}

class _BigStat extends StatelessWidget {
  final String label;
  final String value;

  const _BigStat({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(AppDimens.radiusSmall),
        border: Border.all(color: AppColors.strongBorder),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label.toUpperCase(),
            style:
                AppText.microLabel.copyWith(fontSize: 9, letterSpacing: 1.2),
          ),
          const SizedBox(height: 2),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(
              value,
              style: AppText.mono.copyWith(
                fontSize: 17,
                fontWeight: FontWeight.w800,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
