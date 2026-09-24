import 'package:flutter/material.dart';

import '../../theme/app_colors.dart';

/// Shared "no data yet" placeholder used by all tiles.
///
/// Wrapped in a [FittedBox] so tiny tiles scale it down instead of
/// overflowing. The optional [hint] tells the user what to do next
/// (connect, replay, …) — pass a tile-specific one where it helps.
class WaitingForData extends StatelessWidget {
  final bool compact;

  final String? hint;

  const WaitingForData({super.key, this.compact = false, this.hint});

  @override
  Widget build(BuildContext context) {
    final tip = hint ?? 'Connect a port or replay a flight';
    return FittedBox(
      fit: BoxFit.scaleDown,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.show_chart,
            size: compact ? 24 : 28,
            color: AppColors.strongBorder,
          ),
          const SizedBox(height: 6),
          Text(
            'WAITING FOR DATA…',
            style: AppText.microLabel.copyWith(
              fontSize: 9.5,
              color: AppColors.faint,
            ),
          ),
          if (!compact) ...[
            const SizedBox(height: 3),
            Text(
              tip,
              textAlign: TextAlign.center,
              style: AppText.microLabel.copyWith(
                fontSize: 8,
                letterSpacing: 0.6,
                color: AppColors.faint,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Shared "this connector never provides this" placeholder, sibling of
/// [WaitingForData].
///
/// Tiles show this (instead of waiting forever) when the active
/// connector's [FieldCapabilities] exclude the field they render — e.g. a
/// baro-only connector in the GPS map tile. Same layout language as
/// [WaitingForData] so the two states read as kin.
class NotProvidedByConnector extends StatelessWidget {
  /// Human field name, e.g. `'GPS position'`.
  final String field;

  /// Connector display name, e.g. `'MOCK'`.
  final String connectorName;

  final bool compact;

  const NotProvidedByConnector({
    super.key,
    required this.field,
    required this.connectorName,
    this.compact = false,
  });

  @override
  Widget build(BuildContext context) {
    return FittedBox(
      fit: BoxFit.scaleDown,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.block_outlined,
            size: compact ? 24 : 28,
            color: AppColors.strongBorder,
          ),
          const SizedBox(height: 6),
          Text(
            'NOT PROVIDED',
            style: AppText.microLabel.copyWith(
              fontSize: 9.5,
              color: AppColors.faint,
            ),
          ),
          if (!compact) ...[
            const SizedBox(height: 3),
            Text(
              '$field · $connectorName connector',
              textAlign: TextAlign.center,
              style: AppText.microLabel.copyWith(
                fontSize: 8,
                letterSpacing: 0.6,
                color: AppColors.faint,
              ),
            ),
          ],
        ],
      ),
    );
  }
}
