import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/replay_controller.dart';
import '../../state/telemetry_store.dart';
import '../../theme/app_colors.dart';
import './brand_mark.dart';
import './launch_site_button.dart';
import './link_stats_button.dart';
import './playback_bar.dart';
import './recording_controls.dart';
import '../screens/router.dart';
import './serial_controls.dart';

/// Always-visible top chrome ("Precision Light").
///
/// Three zones: brand · centered live controls (port + link icon, combined
/// stats, launch site, record) · menu. The center group keeps fixed-width
/// slots so nothing shifts when the link comes up or values repaint. Reset
/// lives in the menu. While a replay is active the live zones collapse into
/// the playback controls — the app is not listening to the radio during a
/// replay.
class TopBar extends ConsumerWidget {
  const TopBar({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final replaying = ref.watch(replayProvider).isActive;

    return Container(
      height: AppDimens.topBarHeight,
      decoration: BoxDecoration(
        color: AppColors.card,
        border: Border(bottom: BorderSide(color: AppColors.border)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          // NOTE: intentionally non-const throughout this row — const
          // instances are identical across builds, so the framework skips
          // rebuilding the subtree and dynamic AppColors would freeze on
          // theme flips (this is what stuck the wordmark in one palette).
          Padding(
            padding: const EdgeInsets.only(left: 16, right: 4),
            child: MouseRegion(
              cursor: SystemMouseCursors.click,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => ref
                    .read(appRouterProvider.notifier)
                    .go(AppScreen.dashboard),
                child: Tooltip(
                  message: 'Back to Dashboard',
                  child: BrandMark(),
                ),
              ),
            ),
          ),
          if (replaying)
            Expanded(
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16),
                child: PlaybackBar(),
              ),
            )
          else
            // NOTE: intentionally non-const — const children would freeze
            // across dark-mode flips (AppColors resolves dynamically).
            Expanded(
              child: Align(
                alignment: Alignment.center,
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      SerialControls(),
                      SizedBox(width: 8),
                      LinkStatsButton(),
                      SizedBox(width: 8),
                      LaunchSiteButton(),
                      SizedBox(width: 8),
                      RecordingControls(),
                    ],
                  ),
                ),
              ),
            ),
          Padding(
            padding: const EdgeInsets.only(right: 10),
            child: _NavMenu(),
          ),
        ],
      ),
    );
  }
}

/// Top-right menu: app screens plus the flight reset action.
///
/// Reset lives here rather than as a bar icon so the top bar holds only
/// link + record controls — one menu for everything else.
class _NavMenu extends ConsumerWidget {
  const _NavMenu();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final current = ref.watch(appRouterProvider);
    final hasData = (ref.watch(telemetryStoreProvider).packetCount) > 0;
    // Resetting mid-replay would corrupt the replay state.
    final replaying = ref.watch(replayProvider).isActive;
    final canReset = hasData && !replaying;

    return MenuAnchor(
      builder: (context, controller, child) => IconButton(
        onPressed: () =>
            controller.isOpen ? controller.close() : controller.open(),
        icon: const Icon(Icons.menu),
        iconSize: 20,
        tooltip: 'Menu',
        style: IconButton.styleFrom(
          minimumSize: const Size(32, 32),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          padding: EdgeInsets.zero,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppDimens.radiusSmall),
          ),
        ),
      ),
      menuChildren: [
        for (final screen in AppScreen.values)
          MenuItemButton(
            leadingIcon: Icon(
              screen.icon,
              size: 18,
              color: screen == current ? AppColors.pinkDeep : AppColors.mutedForeground,
            ),
            style: MenuItemButton.styleFrom(
              minimumSize: const Size.fromHeight(38),
              foregroundColor: screen == current
                  ? AppColors.foreground
                  : AppColors.mutedForeground,
              backgroundColor: screen == current ? AppColors.pinkSoft : null,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(AppDimens.radiusSmall),
              ),
            ),
            onPressed: () => ref.read(appRouterProvider.notifier).go(screen),
            child: Text(screen.label),
          ),
        MenuItemButton(
          leadingIcon: Icon(
            Icons.restart_alt,
            size: 18,
            color:
                canReset ? AppColors.destructive : AppColors.mutedForeground,
          ),
          style: MenuItemButton.styleFrom(
            minimumSize: const Size.fromHeight(38),
            foregroundColor: canReset
                ? AppColors.destructive
                : AppColors.mutedForeground,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(AppDimens.radiusSmall),
            ),
          ),
          onPressed: canReset ? () => _confirmReset(context, ref) : null,
          child: const Text('Clear buffers…'),
        ),
      ],
    );
  }

  /// Clears the flight buffers: history buffer, dead reckoning, max altitude,
  /// max speed/accel and the battery discharge average (all derived from the
  /// history, so one reset covers everything).
  Future<void> _confirmReset(BuildContext context, WidgetRef ref) {
    return showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Clear buffers?'),
        content: const Text(
          'This discards the current flight — track, max values and '
          'averages — and starts fresh. Recordings on disk are kept.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
                backgroundColor: AppColors.destructive),
            onPressed: () {
              // Drop focus first: yanking a focused subtree out from under
              // the engine trips the Windows accessibility bridge (AXTree
              // error) when every tile flips to "waiting" at once.
              FocusManager.instance.primaryFocus?.unfocus();
              ref.read(telemetryStoreProvider.notifier).reset();
              Navigator.of(dialogContext).pop();
            },
            child: const Text('Clear'),
          ),
        ],
      ),
    );
  }
}
