import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../flights/replay_controller.dart';
import '../src/telemetry/telemetry_store.dart';
import '../theme/app_colors.dart';
import 'brand_mark.dart';
import 'packet_rate_indicator.dart';
import 'playback_bar.dart';
import 'recording_controls.dart';
import 'router.dart';
import 'serial_controls.dart';

/// Always-visible top chrome ("Precision Light").
///
/// A single bar: brand · live groups (link, packets, recording, reset) ·
/// menu. No micro-labels — every group is self-explanatory at 32px height.
/// While a replay is active, the live groups are replaced by the playback
/// controls — the app is not listening to the radio during a replay.
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
          Padding(
            padding: EdgeInsets.only(left: 16, right: 4),
            child: BrandMark(),
          ),
          Expanded(
            child: replaying
                ? Padding(
                    padding: EdgeInsets.symmetric(horizontal: 16),
                    child: PlaybackBar(),
                  )
                : const SizedBox(),
          ),
          if (!replaying) ...[
            // NOTE: intentionally non-const — const children would freeze
            // across dark-mode flips (AppColors resolves dynamically).
            SerialControls(),
            const SizedBox(width: 12),
            PacketRateIndicator(),
            const SizedBox(width: 12),
            RecordingControls(),
            const SizedBox(width: 4),
            ResetFlightButton(),
            const SizedBox(width: 12),
          ],
          const Padding(
            padding: EdgeInsets.only(right: 10),
            child: _NavMenu(),
          ),
        ],
      ),
    );
  }
}

/// Resets the flight context: history buffer, dead reckoning, max altitude,
/// max speed/accel and the battery discharge average (all derived from the
/// history, so one reset covers everything). Hidden during replay.
class ResetFlightButton extends ConsumerWidget {
  const ResetFlightButton({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hasData = (ref.watch(telemetryStoreProvider).packetCount) > 0;
    return MouseRegion(
      cursor: hasData ? SystemMouseCursors.click : SystemMouseCursors.basic,
      child: IconButton(
        tooltip: 'Reset flight context (clears track, max values, averages)',
        onPressed: hasData ? () => _confirm(context, ref) : null,
        icon: const Icon(Icons.restart_alt),
        iconSize: 19,
        color: AppColors.mutedForeground,
        hoverColor: AppColors.dangerSoft,
        style: IconButton.styleFrom(
          minimumSize: const Size(32, 32),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          padding: EdgeInsets.zero,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppDimens.radiusSmall),
          ),
        ),
      ),
    );
  }

  Future<void> _confirm(BuildContext context, WidgetRef ref) {
    return showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Reset flight context?'),
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
              // error) when every widget flips to "waiting" at once.
              FocusManager.instance.primaryFocus?.unfocus();
              ref.read(telemetryStoreProvider.notifier).reset();
              Navigator.of(dialogContext).pop();
            },
            child: const Text('Reset'),
          ),
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
      ],
    );
  }
}
