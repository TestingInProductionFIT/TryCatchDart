import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../state/telemetry_store.dart';
import '../../theme/app_colors.dart';
import '../components/centered_stat.dart';

/// Peak barometric altitude (m AGL) reached in the current session.
///
/// Split out of the old stats panel so the headline number can live in its
/// own tile; the position panel keeps the live GPS / dead-reckoning readout.
/// Just the peak — no live value.
class MaxAltitudeTile extends ConsumerWidget {
  const MaxAltitudeTile({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(telemetryStoreProvider);
    final maxAlt = state.history.isEmpty ? null : state.maxAltitude;

    // No headline label — the card header already says what this is.
    // CenteredValue scale-downs in short tiles, so no extra breakpoint.
    return Center(
      child: CenteredValue(
        value: formatAltitudeM(maxAlt),
        valueColor: AppColors.seriesAltitude,
      ),
    );
  }
}
