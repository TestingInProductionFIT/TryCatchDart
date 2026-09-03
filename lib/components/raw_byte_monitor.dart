import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:serial/serial.dart';
import 'package:trycatch/src/collections/ring_buffer.dart';
import 'package:trycatch/src/telemetry/telemetry_provider.dart';
import 'package:trycatch/theme/app_colors.dart';

/// Full-screen raw packet feed for debugging: a fixed window of the most
/// recent packets in monospace hex. Shows what fits — no scrolling.
class RawByteMonitor extends ConsumerStatefulWidget {
  const RawByteMonitor({super.key});

  @override
  ConsumerState<RawByteMonitor> createState() => _RawByteMonitorState();
}

class _RawByteMonitorState extends ConsumerState<RawByteMonitor> {
  final RingBuffer<TelemetryPacket> _packetBuffer =
      RingBuffer<TelemetryPacket>(1000);

  static const double _lineHeight = 20;

  @override
  Widget build(BuildContext context) {
    ref.listen(telemetryStreamProvider, (_, next) {
      next.whenData((packet) {
        _packetBuffer.push(packet);
        setState(() {});
      });
    });

    return LayoutBuilder(
      builder: (context, constraints) {
        // Reserve the container's vertical padding so the lines never
        // overflow the bottom edge.
        final lineCount =
            ((constraints.maxHeight - 8) / _lineHeight).floor().clamp(0, 100);

        // RingBuffer index 0 is the newest packet; render the newest lines
        // that fit, oldest first.
        final lines = <Widget>[];
        for (var i = lineCount - 1; i >= 0; i--) {
          if (i >= _packetBuffer.length) continue;
          lines.add(SizedBox(
            height: _lineHeight,
            child: _PacketLine(packet: _packetBuffer[i]),
          ));
        }

        return Container(
          color: AppColors.background,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          child: _packetBuffer.isEmpty
              ? const Center(
                  child: Text(
                    'Awaiting packets…',
                    style: TextStyle(
                        fontSize: 13, color: AppColors.mutedForeground),
                  ),
                )
              // Center the block in the leftover space, like mx-auto.
              : Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: lines,
                  ),
                ),
        );
      },
    );
  }
}

class _PacketLine extends StatelessWidget {
  final TelemetryPacket packet;

  const _PacketLine({required this.packet});

  @override
  Widget build(BuildContext context) {
    final hex = packet.rawData
        .map((b) => b.toRadixString(16).padLeft(2, '0').toUpperCase())
        .join(' ');

    final decoded = FrameCodec.decode(packet.rawData, receivedAtMs: 0);
    final caption = decoded == null
        ? 'undecodable'
        : '${decoded.fsmState.label} · ${decoded.baroAltitude.toStringAsFixed(1)} m';

    return Align(
      alignment: Alignment.centerLeft,
      child: Text.rich(
        TextSpan(
          children: [
            TextSpan(
              text:
                  '[${DateTime.fromMillisecondsSinceEpoch(packet.receivedAtMs).toIso8601String().substring(11, 23)}] ',
              style: const TextStyle(color: AppColors.mutedForeground),
            ),
            TextSpan(text: hex),
            TextSpan(
              text: ' · $caption',
              style: const TextStyle(color: AppColors.mutedForeground),
            ),
          ],
        ),
        maxLines: 1,
        overflow: TextOverflow.clip,
        style: const TextStyle(
          fontFamily: 'Consolas',
          fontFamilyFallback: ['Courier New', 'monospace'],
          fontSize: 12,
          color: AppColors.foreground,
        ),
      ),
    );
  }
}
