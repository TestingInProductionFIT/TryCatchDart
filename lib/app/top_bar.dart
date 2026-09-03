import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../flights/replay_controller.dart';
import '../theme/app_colors.dart';
import 'brand_mark.dart';
import 'packet_rate_indicator.dart';
import 'playback_bar.dart';
import 'recording_controls.dart';
import 'router.dart';
import 'serial_controls.dart';

/// Always-visible segmented top chrome ("Precision Light").
///
/// A single white bar divided into cells by hairline rules; each cell shows a
/// monospace uppercase micro-label above its content. Normally:
/// brand · link · packets · recording · menu. While a replay is active, the
/// serial/recording groups are replaced by the playback controls — the app is
/// not listening to the radio during a replay.
class TopBar extends ConsumerWidget {
  const TopBar({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final replaying = ref.watch(replayProvider).isActive;

    return Container(
      height: AppDimens.topBarHeight,
      decoration: const BoxDecoration(
        color: AppColors.card,
        border: Border(bottom: BorderSide(color: AppColors.border)),
      ),
      child: Row(
        children: [
          const _Cell(
            padding: EdgeInsets.symmetric(horizontal: 16),
            child: BrandMark(),
          ),
          Expanded(
            child: replaying
                ? const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 16),
                    child: PlaybackBar(),
                  )
                : const SizedBox(),
          ),
          if (!replaying) ...[
            const SizedBox(width: 8),
            _Cell(
              label: 'LINK',
              child: const SerialControls(),
            ),
            const SizedBox(width: 20),
            _Cell(
              label: 'PACKETS',
              child: const PacketRateIndicator(),
            ),
            const SizedBox(width: 20),
            _Cell(
              label: 'REC',
              child: const RecordingControls(),
            ),
          ],
          _Cell(
            padding: const EdgeInsets.only(left: 16, right: 8),
            child: const _NavMenu(),
          ),
        ],
      ),
    );
  }
}

/// One segment of the top bar: optional micro-label above the content.
class _Cell extends StatelessWidget {
  final String? label;
  final Widget child;
  final EdgeInsetsGeometry padding;

  const _Cell({this.label, required this.child, this.padding = EdgeInsets.zero});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: padding,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (label != null) ...[
            Text(label!, style: AppText.microLabel.copyWith(fontSize: 8, color: AppColors.faint)),
            const SizedBox(height: 2),
          ],
          child,
        ],
      ),
    );
  }
}

/// Top-right menu for switching between the app screens.
class _NavMenu extends ConsumerWidget {
  const _NavMenu();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final current = ref.watch(appRouterProvider);

    return MenuAnchor(
      builder: (context, controller, child) => IconButton(
        onPressed: () =>
            controller.isOpen ? controller.close() : controller.open(),
        icon: const Icon(Icons.menu),
        tooltip: 'Menu',
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
      ],
    );
  }
}
