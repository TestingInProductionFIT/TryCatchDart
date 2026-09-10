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
    // Display-only live readout (repaints ~10 Hz) — excluded from semantics
    // so it doesn't churn the Windows accessibility bridge (see
    // CenteredValue); interactive controls keep theirs.
    return ExcludeSemantics(
      child: Padding(
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
      ),
    );
  }
}
