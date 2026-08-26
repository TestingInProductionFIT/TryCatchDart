import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:serial/serial.dart';
import 'package:trycatch/src/collections/ring_buffer.dart';
import 'package:trycatch/src/telemetry/telemetry_provider.dart';

/// Displays a live feed of parsed [TelemetryPacket]s received from the serial worker.
///
/// Uses a fixed-capacity [RingBuffer] to retain only the most recent packets in memory,
/// ensuring zero reallocation and flat memory consumption even during multi-hour runs.
class RawByteMonitor extends ConsumerStatefulWidget {
  const RawByteMonitor({super.key});

  @override
  ConsumerState<RawByteMonitor> createState() => _RawByteMonitorState();
}

class _RawByteMonitorState extends ConsumerState<RawByteMonitor> {
  final RingBuffer<TelemetryPacket> _packetBuffer =
      RingBuffer<TelemetryPacket>(1000);
  int _totalPacketsReceived = 0;

  @override
  Widget build(BuildContext context) {
    ref.listen(telemetryStreamProvider, (_, next) {
      next.whenData((packet) {
        setState(() {
          _totalPacketsReceived++;
          _packetBuffer.push(packet);
        });
      });
    });

    final streamState = ref.watch(telemetryStreamProvider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (streamState.hasError)
          Text(
            'Stream error: ${streamState.error}',
            style: const TextStyle(color: Colors.red),
          )
        else if (_packetBuffer.isEmpty)
          const Padding(
            padding: EdgeInsets.only(bottom: 8.0),
            child: Text('Awaiting packets...'),
          ),
        Text(
          'Packets: $_totalPacketsReceived total (buffered last ${_packetBuffer.length}/${_packetBuffer.capacity})',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        SizedBox(
          height: 600,
          child: ListView.builder(
            itemCount: _packetBuffer.length,
            itemBuilder: (context, index) {
              // RingBuffer index 0 is the newest packet, index 1 is 2nd newest, etc.
              final packet = _packetBuffer[index];
              final hex = packet.rawData
                  .map((b) => b.toRadixString(16).padLeft(2, '0').toUpperCase())
                  .join(' ');

              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 2.0),
                child: Text(
                  '[${packet.receivedAtMs}ms] $hex',
                  style: const TextStyle(fontFamily: 'Monospace', fontSize: 12),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}
