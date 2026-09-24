import 'package:flutter/material.dart';

import '../../../theme/app_colors.dart';

/// Big mono readout + trailing badge shared by the single-value chart tiles
/// (battery, hall): value on the left, [trailing] (a [StatusPill]
/// or a micro-label) pinned right.
class ChartValueHeader extends StatelessWidget {
  final String value;

  /// Value color; defaults to foreground (muted when [dimmed]).
  final Color? valueColor;

  final Widget? trailing;

  final double fontSize;

  final bool dimmed;

  /// Space below the header (hall pairs it with its own [SizedBox]).
  final double bottomPadding;

  const ChartValueHeader({
    super.key,
    required this.value,
    this.valueColor,
    this.trailing,
    this.fontSize = 18,
    this.dimmed = false,
    this.bottomPadding = 6,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(bottom: bottomPadding),
      child: Row(
        children: [
          Flexible(
            child: Text(
              value,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppText.mono.copyWith(
                fontSize: fontSize,
                fontWeight: FontWeight.w800,
                fontFeatures: const [FontFeature.tabularFigures()],
                color:
                    valueColor ??
                    (dimmed
                        ? AppColors.mutedForeground
                        : AppColors.foreground),
              ),
            ),
          ),
          if (trailing != null) ...[const SizedBox(width: 8), trailing!],
        ],
      ),
    );
  }
}
