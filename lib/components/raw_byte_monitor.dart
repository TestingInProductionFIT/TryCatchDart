import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:trycatch/src/serial/provider.dart';

/// A diagnostic widget that listens to [rawBytesStreamProvider] and displays
/// a history of incoming serial byte buffers formatted as hexadecimal values,
/// with the newest entries at the top.
class RawByteMonitor extends ConsumerStatefulWidget {
  const RawByteMonitor({super.key});

  @override
  ConsumerState<RawByteMonitor> createState() => _RawByteMonitorState();
}

class _RawByteMonitorState extends ConsumerState<RawByteMonitor> {
  // Holds the history of formatted log lines (newest first)
  final List<String> _history = [];

  @override
  Widget build(BuildContext context) {
    // Listen to the stream using ref.listen so we can append to local state
    ref.listen(rawBytesStreamProvider, (_, next) {
      next.whenData((chunk) {
        if (chunk.isEmpty) return;

        // Format each byte as a 2-digit uppercase hexadecimal pair
        final hexString = chunk
            .map((b) => b.toRadixString(16).padLeft(2, '0').toUpperCase())
            .join(' ');

        final logEntry = 'Received ${chunk.length} bytes: $hexString';

        setState(() {
          // Insert at the top (index 0)
          _history.insert(0, logEntry);
        });
      });
    });

    final streamState = ref.watch(rawBytesStreamProvider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        // Status header
        if (streamState.hasError)
          Text(
            'Serial Error: ${streamState.error}',
            style: const TextStyle(color: Colors.red),
          )
        else if (_history.isEmpty)
          const Padding(
            padding: EdgeInsets.only(bottom: 8.0),
            child: Text('Awaiting raw data...'),
          ),
        Text(
          'Packets: ${_history.length}',
          style: Theme.of(context).textTheme.bodySmall,
        ),

        // Constrained height container for the history list so it won't crash parent columns
        SizedBox(
          height: 700, // Adjust this height as needed for your UI
          child: ListView.builder(
            itemCount: _history.length,
            itemBuilder: (context, index) {
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 2.0),
                child: Text(
                  _history[index],
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
