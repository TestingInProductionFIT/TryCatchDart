import 'package:flutter/material.dart';

import '../../theme/app_colors.dart';

/// Centred headline readout shared by the single-value tiles (FSM state,
/// max altitude, nose cone, position cards): optional icon, big centred
/// value, small sublabel line under it.
///
/// Layout-neutral (a `min`-axis [Column]) — callers provide the surrounding
/// `Center`/`Expanded` that bounds it.
class CenteredValue extends StatelessWidget {
  final IconData? icon;

  final double iconSize;

  final String value;

  final Color? valueColor;

  final double valueSize;

  /// Render the value in the micro-label voice instead of the mono headline.
  final bool microValue;

  final double letterSpacing;

  /// How the value (and icon) shrink inside tight tiles.
  final BoxFit fit;

  /// Small mono line under the value (`null` hides it).
  final String? sublabel;

  final double sublabelSize;

  final Color? sublabelColor;

  /// Gap between the value and the sublabel.
  final double sublabelGap;

  const CenteredValue({
    super.key,
    this.icon,
    this.iconSize = 44,
    required this.value,
    this.valueColor,
    this.valueSize = 30,
    this.microValue = false,
    this.letterSpacing = 0,
    this.fit = BoxFit.scaleDown,
    this.sublabel,
    this.sublabelSize = 11,
    this.sublabelColor,
    this.sublabelGap = 4,
  });

  @override
  Widget build(BuildContext context) {
    final color = valueColor ?? AppColors.foreground;
    final content = Column(
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.center,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (icon != null)
          FittedBox(
            fit: fit,
            child: Icon(icon, size: iconSize, color: color),
          ),
        if (icon != null) const SizedBox(height: 6),
        FittedBox(
          fit: fit,
          alignment: Alignment.center,
          child: Text(
            value,
            textAlign: TextAlign.center,
            style: microValue
                ? AppText.microLabel.copyWith(
                    fontSize: valueSize,
                    letterSpacing: letterSpacing == 0 ? 1.6 : letterSpacing,
                    color: color,
                  )
                : AppText.mono.copyWith(
                    fontSize: valueSize,
                    fontWeight: FontWeight.w800,
                    letterSpacing: letterSpacing,
                    color: color,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
          ),
        ),
        if (sublabel != null) ...[
          SizedBox(height: sublabelGap),
          Text(
            sublabel!,
            textAlign: TextAlign.center,
            style: AppText.mono.copyWith(
              fontSize: sublabelSize,
              fontWeight: FontWeight.w600,
              color: sublabelColor ?? AppColors.mutedForeground,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ],
    );

    // A FittedBox only shrinks against *bounded* constraints, but a Column
    // hands its children unbounded height — so in short tiles the headline
    // kept its natural size and overflowed (yellow stripes). When the
    // incoming box is fully bounded, pin a tight box of exactly that size
    // around an inner width-fixed column: the FittedBox then scales the
    // whole block (value + sublabel together) down to fit.
    // ExcludeSemantics: live values repaint up to ~10 Hz, and on desktop
    // semantics are always on, so every text change crosses the (buggy)
    // Windows accessibility bridge (AXTree "nodes left pending" spam).
    // These readouts are display-only — interactive controls keep semantics.
    return ExcludeSemantics(
      child: LayoutBuilder(
        builder: (context, constraints) {
          final maxW = constraints.maxWidth;
          final maxH = constraints.maxHeight;
          if (!maxW.isFinite || !maxH.isFinite) return content;
          return SizedBox(
            width: maxW,
            height: maxH,
            child: FittedBox(
              fit: fit,
              alignment: Alignment.center,
              child: SizedBox(width: maxW, child: content),
            ),
          );
        },
      ),
    );
  }
}
