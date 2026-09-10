import 'package:flutter/material.dart';

import '../../theme/app_colors.dart';

/// The standard surface primitive: white panel, hairline border, radius 9.
///
/// With a [title]/[trailing] the card renders the Precision-Light header
/// strip: tinted band, hairline bottom rule, a pink marker square and the
/// title as a monospace uppercase micro-label. Used for dashboard tiles,
/// dialogs and panels so the whole app shares one card look.
///
/// [fillChild] controls sizing: `true` stretches the child to fill the card
/// (requires a bounded-height parent — the workspace grid provides one);
/// `false` shrink-wraps the card around its child (lists, dialogs, forms).
class AppCard extends StatelessWidget {
  final String? title;
  final String? subtitle;
  final Widget? trailing;
  final Widget? child;
  final EdgeInsetsGeometry? padding;
  final Color? borderColor;
  final double? radius;
  final bool fillChild;

  const AppCard({
    super.key,
    this.title,
    this.subtitle,
    this.trailing,
    this.child,
    this.padding,
    this.borderColor,
    this.radius,
    this.fillChild = false,
  });

  /// Whether a header row (title / trailing) should be rendered.
  bool get _hasHeader => title != null || trailing != null;

  @override
  Widget build(BuildContext context) {
    final body = child == null
        ? null
        : Padding(
            padding: padding ?? const EdgeInsets.all(AppDimens.cardPadding),
            child: child,
          );

    return Container(
      // Hard-edge clip: an anti-aliased clip on every grid tile was enough to
      // blank the whole grid on Impeller/OpenGLES (Windows ARM64), and the
      // only thing being clipped is the header divider's corner rounding.
      clipBehavior: Clip.hardEdge,
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(radius ?? AppDimens.radius),
        border: Border.all(color: borderColor ?? AppColors.border),
        // No BoxShadow here: shadowed + clipped cards are the Impeller/GL
        // blank-paint trigger — see windows/runner/flutter_window.cpp history.
      ),
      child: fillChild
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (_hasHeader) _buildHeader(),
                if (body != null) Expanded(child: body),
              ],
            )
          : Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (_hasHeader) _buildHeader(),
                ?body,
              ],
            ),
    );
  }

  Widget _buildHeader() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
              AppDimens.cardPadding, 10, AppDimens.cardPadding, 8),
          child: Row(
            children: [
              if (title != null) ...[
                Container(
                  width: 6,
                  height: 6,
                  decoration: BoxDecoration(
                    color: AppColors.pink,
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  title!.toUpperCase(),
                  style: AppText.microLabel.copyWith(letterSpacing: 1.1),
                  overflow: TextOverflow.ellipsis,
                ),
              ],
              if (subtitle != null) ...[
                if (title != null) const SizedBox(width: 8),
                Text(
                  subtitle!,
                  style: TextStyle(fontSize: 11, color: AppColors.faint),
                  overflow: TextOverflow.ellipsis,
                ),
              ],
              if (trailing != null) ...[
                const Spacer(),
                trailing!,
              ] else if (title == null)
                const Spacer(),
            ],
          ),
        ),
        Divider(height: 1, thickness: 1, color: AppColors.border),
      ],
    );
  }
}
