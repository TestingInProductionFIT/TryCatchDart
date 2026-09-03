import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:serial/serial.dart';

import '../theme/app_colors.dart';
import '../theme/widgets/status_pill.dart';
import '/src/telemetry/telemetry_provider.dart';

/// Compact connection control for the LINK cell of the top bar.
///
/// Both states render the same skeleton — a selector area (dropdown or
/// port pill) plus a fixed-width action button — so the bar never shifts.
class SerialControls extends ConsumerWidget {
  static const double width = 104 + 8 + 104;

  const SerialControls({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ports = ref.watch(availablePortsProvider).value ?? const [];
    final config = ref.watch(serialConfigProvider);
    final status =
        ref.watch(serialStatusProvider).value ?? const SerialWorkerStatus();
    final notifier = ref.read(serialConfigProvider.notifier);

    final selected = config.selectedPort;
    final effectiveSelected = selected ??
        (ports.contains(status.connectedPort) ? status.connectedPort : null);

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Selector area: dropdown when disconnected, port pill when connected.
        SizedBox(
          width: 104,
          height: 32,
          child: status.isConnected
              ? Center(
                  child: StatusPill(
                    label: status.connectedPort ?? '',
                    color: AppColors.success,
                    height: 28,
                  ),
                )
              : Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  decoration: BoxDecoration(
                    color: AppColors.card,
                    borderRadius:
                        BorderRadius.circular(AppDimens.radiusSmall),
                    border: Border.all(color: AppColors.border),
                  ),
                  child: DropdownButtonHideUnderline(
                    child: DropdownButton<String>(
                      value: effectiveSelected,
                      hint: const Text('Port', style: TextStyle(fontSize: 12.5)),
                      isDense: true,
                      isExpanded: true,
                      borderRadius:
                          BorderRadius.circular(AppDimens.radiusSmall),
                      style: const TextStyle(
                        fontSize: 12.5,
                        color: AppColors.foreground,
                        fontWeight: FontWeight.w600,
                        fontFamily: AppText.monoFamily,
                      ),
                      icon: const Icon(Icons.unfold_more,
                          size: 14, color: AppColors.mutedForeground),
                      items: ports
                          .map((p) => DropdownMenuItem(value: p, child: Text(p)))
                          .toList(),
                      onChanged: (p) => notifier.setPort(p),
                    ),
                  ),
                ),
        ),
        const SizedBox(width: 8),
        SizedBox(
          width: 104,
          height: 32,
          child: status.isConnected
              ? FilledButton.tonal(
                  onPressed: notifier.disconnect,
                  style: FilledButton.styleFrom(
                    backgroundColor: AppColors.muted,
                    foregroundColor: AppColors.mutedForeground,
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    minimumSize: const Size(0, 32),
                    textStyle: const TextStyle(
                        fontSize: 12.5, fontWeight: FontWeight.w600),
                  ),
                  child: const Text(
                    'Disconnect',
                    overflow: TextOverflow.ellipsis,
                  ),
                )
              : FilledButton(
                  onPressed:
                      effectiveSelected == null ? null : notifier.connect,
                  style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    minimumSize: const Size(0, 32),
                    textStyle: const TextStyle(
                        fontSize: 12.5, fontWeight: FontWeight.w600),
                  ),
                  child: const Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.link, size: 14),
                      SizedBox(width: 5),
                      Flexible(
                        child: Text(
                          'Connect',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ),
        ),
      ],
    );
  }
}
