import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:serial/serial.dart';
import 'package:trycatch/src/telemetry/telemetry_provider.dart';

/// A toolbar widget providing controls for serial port connection management.
///
/// Port hardware settings (baud rate, parity, stop bits) are centralized in
/// [SerialHardwareConfig] in `packages/serial/lib/constants.dart`.
class SerialToolbar extends ConsumerWidget {
  const SerialToolbar({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final status =
        ref.watch(serialStatusProvider).value ?? const SerialWorkerStatus();
    final ports = ref.watch(availablePortsProvider).value ?? const [];

    final config = ref.watch(serialConfigProvider);
    final notifier = ref.read(serialConfigProvider.notifier);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Wrap(
        spacing: 12,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          // Connection Status Badge
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: status.isConnected ? Colors.green : Colors.grey.shade700,
              borderRadius: BorderRadius.circular(16),
            ),
            child: Text(
              status.isConnected ? 'CONNECTED' : 'DISCONNECTED',
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.bold,
                fontSize: 11,
              ),
            ),
          ),

          // Port Selector Dropdown
          DropdownButton<String>(
            value: config.selectedPort,
            hint: const Text('Select Port'),
            items: ports
                .map((p) => DropdownMenuItem(value: p, child: Text(p)))
                .toList(),
            onChanged: status.isConnected ? null : notifier.setPort,
          ),

          // Port Discovery Refresh Button
          IconButton(
            icon: const Icon(Icons.refresh, size: 20),
            onPressed: status.isConnected ? null : notifier.refreshPorts,
            tooltip: 'Refresh Ports',
          ),

          const SizedBox(width: 12),

          // Connect / Disconnect Action Button
          if (!status.isConnected)
            ElevatedButton.icon(
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.green.shade700,
                foregroundColor: Colors.white,
              ),
              icon: const Icon(Icons.power, size: 16),
              label: const Text('Connect'),
              onPressed: config.selectedPort == null ? null : notifier.connect,
            )
          else
            ElevatedButton.icon(
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.red.shade700,
                foregroundColor: Colors.white,
              ),
              icon: const Icon(Icons.power_off, size: 16),
              label: const Text('Disconnect'),
              onPressed: notifier.disconnect,
            ),
        ],
      ),
    );
  }
}
