import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:serial/serial.dart';

import '../theme/app_colors.dart';
import '/src/telemetry/telemetry_provider.dart';

/// Compact connection control for the top bar: one box, two states.
///
/// Both states render the same skeleton — a 104px selector area (borderless
/// dropdown or green port name) plus a 104px action button — so the bar never
/// shifts when the link comes up.
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
        // Selector area: borderless dropdown when disconnected, green port
        // name when connected.
        SizedBox(
          width: 104,
          height: 32,
          child: status.isConnected
              ? Center(
                  child: Text(
                    status.connectedPort ?? '',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppText.mono.copyWith(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w700,
                      color: AppColors.success,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                )
              : DropdownButtonHideUnderline(
                  child: DropdownButton<String>(
                    value: effectiveSelected,
                    hint: const Text('Port', style: TextStyle(fontSize: 12.5)),
                    isDense: true,
                    isExpanded: true,
                    borderRadius:
                        BorderRadius.circular(AppDimens.radiusSmall),
                      style: TextStyle(
                        fontSize: 12.5,
                        color: AppColors.foreground,
                        fontWeight: FontWeight.w600,
                        fontFamily: AppText.monoFamily,
                      ),
                      icon: Icon(Icons.unfold_more,
                          size: 14, color: AppColors.mutedForeground),
                    items: ports
                        .map((p) => DropdownMenuItem(value: p, child: Text(p)))
                        .toList(),
                    onChanged: (p) => notifier.setPort(p),
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
