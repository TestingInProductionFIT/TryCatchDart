import 'dart:typed_data';

import '../constants.dart';
import '../worker/protocol.dart';

/// Stateful byte-stream parser that accumulates incoming chunks and extracts
/// complete [TelemetryPacket] instances based on [TelemetryFraming].
class PacketParser {
  final _buf = <int>[];

  /// Feed a raw byte chunk from the serial stream into the parser.
  ///
  /// Returns a list of all complete [TelemetryPacket]s extracted.
  List<TelemetryPacket> feed(Uint8List chunk) {
    _buf.addAll(chunk);
    final packets = <TelemetryPacket>[];

    while (_buf.length >= TelemetryFraming.totalPacketLength) {
      final start = _indexOfStartWord();

      if (start == -1) {
        // Retain only the last byte in case the start word was split across chunks.
        final last = _buf.last;
        _buf.clear();
        _buf.add(last);
        break;
      }

      if (start > 0) {
        // Discard preceding garbage bytes.
        _buf.removeRange(0, start);
      }

      // Check if we have enough bytes for the complete packet.
      if (_buf.length < TelemetryFraming.totalPacketLength) break;

      // Extract payload bytes.
      final payload = Uint8List.fromList(
        _buf.sublist(
          TelemetryFraming.startWordLength,
          TelemetryFraming.totalPacketLength,
        ),
      );

      packets.add(
        TelemetryPacket(
          receivedAtMs: DateTime.now().millisecondsSinceEpoch,
          rawData: payload,
        ),
      );

      // Advance buffer past this packet.
      _buf.removeRange(0, TelemetryFraming.totalPacketLength);
    }

    return packets;
  }

  /// Clears the accumulation buffer.
  void reset() => _buf.clear();

  int _indexOfStartWord() {
    final limit = _buf.length - 1;

    for (var i = 0; i < limit; i++) {
      if (_buf[i] == TelemetryFraming.startByte0 &&
          _buf[i + 1] == TelemetryFraming.startByte1) {
        return i;
      }
    }

    return -1;
  }
}
