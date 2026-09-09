import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../src/telemetry/telemetry_store.dart';
import '../../theme/app_colors.dart';
import '../../theme/widgets/waiting_for_data.dart';

/// Parachute state in the centred widget language: big icon + label,
/// centred both ways. Open orange, stowed faint.
class ParachuteWidget extends ConsumerWidget {
  const ParachuteWidget({super.key});

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
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Flexible(
            child: FittedBox(
              fit: BoxFit.contain,
              child: Icon(Icons.paragliding, size: 44, color: color),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            label,
            textAlign: TextAlign.center,
            style: AppText.microLabel.copyWith(
              fontSize: 11,
              letterSpacing: 1.6,
              color: color,
            ),
          ),
        ],
      ),
    );
  }
}
