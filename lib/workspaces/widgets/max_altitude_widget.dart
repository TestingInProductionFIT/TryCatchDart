import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../src/telemetry/telemetry_store.dart';
import '../../theme/app_colors.dart';

/// Peak barometric altitude (m AGL) reached in the current session.
///
/// Split out of the old stats panel so the headline number can live in its
/// own tile; the position panel keeps the live GPS / dead-reckoning readout.
class MaxAltitudeWidget extends ConsumerWidget {
  const MaxAltitudeWidget({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(telemetryStoreProvider);
    final maxAlt = state.history.isEmpty ? null : state.maxAltitude;
    final current = state.latest?.baroAltitude;

    final value = maxAlt == null
        ? '—'
        : '${maxAlt.toStringAsFixed(maxAlt.abs() >= 100 ? 0 : 1)} m';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.center,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        // No headline label — the card header already says what this is.
        FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.center,
          child: Text(
            value,
            textAlign: TextAlign.center,
            style: AppText.mono.copyWith(
              fontSize: 30,
              fontWeight: FontWeight.w800,
              color: AppColors.seriesAltitude,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ),
        if (current != null) ...[
          const SizedBox(height: 4),
          Text(
            'NOW ${current.toStringAsFixed(current.abs() >= 100 ? 0 : 1)} m',
            textAlign: TextAlign.center,
            style: AppText.mono.copyWith(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: AppColors.mutedForeground,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ],
    );
  }
}
