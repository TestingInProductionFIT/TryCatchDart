import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/telemetry_store.dart';
import '../../theme/app_colors.dart';
import '../components/centered_stat.dart';
import '../components/waiting_for_data.dart';

/// Parachute state in the centred tile language: big icon + label,
/// centred both ways. Open orange, stowed faint.
class ParachuteTile extends ConsumerWidget {
  const ParachuteTile({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final latest = ref.watch(telemetryStoreProvider).latest;
    if (latest == null) {
      return Center(child: WaitingForData());
    }

    final open = latest.fsmState.hasParachute;
    final (Color color, String label, String tooltip) = open
        ? (
            AppColors.warning,
            'OPEN',
            'Parachute open',
          )
        : (
            AppColors.faint,
            'STOWED',
            'Parachute stowed',
          );

    return Tooltip(
      message: tooltip,
      child: Center(
        child: LayoutBuilder(builder: (context, constraints) {
          // Very short tiles drop the label — the icon alone reads clearly.
          if (constraints.maxHeight.isFinite &&
              constraints.maxHeight < 80) {
            return Icon(Icons.paragliding, size: 30, color: color);
          }
          // Small tiles shrink the icon instead of clipping.
          final iconSize = constraints.maxHeight < 90 ? 26.0 : 44.0;
          return CenteredValue(
            icon: Icons.paragliding,
            iconSize: iconSize,
            value: label,
            valueColor: color,
            valueSize: 11,
            microValue: true,
          );
        }),
      ),
    );
  }
}
