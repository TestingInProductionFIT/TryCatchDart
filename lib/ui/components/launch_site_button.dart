import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/app_config.dart';
import '../../state/launch_site_store.dart';
import '../../theme/app_colors.dart';
import './launch_site_dialog.dart';
export './launch_site_dialog.dart';

/// Top-bar launch site button: flag icon + selected site name in a fixed
/// slot, matching the other chrome controls.
///
/// A launch site is mandatory — recordings stamp it into the file header,
/// and the Record button stays disabled until one is set. With nothing
/// selected the button reads SET SITE in amber. Tapping it opens the site
/// dialog: the saved list (tap selects, per-row edit/remove) plus an Add
/// form (name, then either the rocket's current position or manual
/// coordinates).
class LaunchSiteButton extends ConsumerWidget {
  static const double width = AppConfig.launchSiteButtonWidth;

  const LaunchSiteButton({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final site = ref.watch(currentLaunchSiteProvider);

    final accent = site == null ? AppColors.warning : AppColors.mutedForeground;
    return SizedBox(
      width: width,
      height: 32,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: Tooltip(
          message: site == null
              ? 'No launch site selected — set one to enable recording'
              : 'Launch site: ${site.name} — change',
          mouseCursor: SystemMouseCursors.click,
          child: Material(
            color: Colors.transparent,
            borderRadius: BorderRadius.circular(AppDimens.radiusSmall),
            child: InkWell(
              borderRadius: BorderRadius.circular(AppDimens.radiusSmall),
              mouseCursor: SystemMouseCursors.click,
              onTap: () => showLaunchSiteDialog(context),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 10),
                decoration: BoxDecoration(
                  color: site == null
                      ? AppColors.warning.withValues(alpha: 0.12)
                      : Colors.transparent,
                  borderRadius: BorderRadius.circular(AppDimens.radiusSmall),
                  border: Border.all(
                    color: site == null
                        ? AppColors.warning.withValues(alpha: 0.5)
                        : AppColors.strongBorder,
                  ),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.flag_outlined, size: 15, color: accent),
                    const SizedBox(width: 6),
                    Flexible(
                      child: Text(
                        site?.name.toUpperCase() ?? 'SET SITE',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.center,
                        style: AppText.mono.copyWith(
                          fontSize: 11.5,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.4,
                          color: site == null
                              ? Color.lerp(accent, AppColors.foreground, 0.2)
                              : AppColors.foreground,
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
