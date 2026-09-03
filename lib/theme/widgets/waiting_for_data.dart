import 'package:flutter/material.dart';

import '../app_colors.dart';

/// Shared "no data yet" placeholder used by all widgets.
///
/// Wrapped in a [FittedBox] so tiny tiles scale it down instead of
/// overflowing.
class WaitingForData extends StatelessWidget {
  final bool compact;

  const WaitingForData({super.key, this.compact = false});

  @override
  Widget build(BuildContext context) {
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
        ],
      ),
    );
  }
}
