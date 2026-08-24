import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:trycatch/src/serial/provider.dart';

/// A toolbar widget providing controls for serial port connection management.
///
/// Includes:
/// - Connection status badge (Connected / Disconnected)
/// - Serial port dropdown selector with detected ports
/// - Port list refresh action button
/// - Baud rate dropdown selector
/// - Connect / Disconnect action button
class SerialToolbar extends ConsumerWidget {
  const SerialToolbar({super.key});

  /// Standard baud rates supported by the serial port interface.
  static const List<int> baudRates = [
    9600,
    19200,
    38400,
    57600,
    115200,
    230400,
    460800,
    921600,
  ];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final serialState = ref.watch(serialControllerProvider);
    final controller = ref.read(serialControllerProvider.notifier);

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
              color: serialState.isConnected
                  ? Colors.green
                  : Colors.grey.shade700,
              borderRadius: BorderRadius.circular(16),
            ),
            child: Text(
              serialState.isConnected ? 'CONNECTED' : 'DISCONNECTED',
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.bold,
                fontSize: 11,
              ),
            ),
          ),

          // Port Selector Dropdown
          DropdownButton<String>(
            value: serialState.selectedPort,
            hint: const Text('Select Port'),
            items: serialState.availablePorts.map((port) {
              return DropdownMenuItem(value: port, child: Text(port));
            }).toList(),
            onChanged: serialState.isConnected ? null : controller.setPort,
          ),

          // Port Discovery Refresh Button
          IconButton(
            icon: const Icon(Icons.refresh, size: 20),
            onPressed: serialState.isConnected ? null : controller.refreshPorts,
            tooltip: 'Refresh Ports',
          ),

          const SizedBox(width: 8),

          // Baud Rate Selector Dropdown
          DropdownButton<int>(
            value: serialState.baudRate,
            items: baudRates.map((rate) {
              return DropdownMenuItem(value: rate, child: Text('$rate baud'));
            }).toList(),
            onChanged: serialState.isConnected
                ? null
                : (val) => val != null ? controller.setBaudRate(val) : null,
          ),

          const SizedBox(width: 12),

          // Connect / Disconnect Action Button
          if (!serialState.isConnected)
            ElevatedButton.icon(
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.green.shade700,
                foregroundColor: Colors.white,
              ),
              icon: const Icon(Icons.power, size: 16),
              label: const Text('Connect'),
              onPressed: serialState.selectedPort == null
                  ? null
                  : controller.connect,
            )
          else
            ElevatedButton.icon(
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.red.shade700,
                foregroundColor: Colors.white,
              ),
              icon: const Icon(Icons.power_off, size: 16),
              label: const Text('Disconnect'),
              onPressed: controller.disconnect,
            ),
        ],
      ),
    );
  }
}
