import 'dart:typed_data';

import '../constants.dart';
import '../telemetry/frame_codec.dart';
import '../worker/protocol.dart';

/// Stateful byte-stream parser that accumulates incoming chunks and extracts
/// complete [TelemetryPacket] instances based on the configured framing.
///
/// Frames whose trailing CRC16 does not match are treated as garbage and
/// silently dropped — the buffer still advances past them so a corrupt frame
/// cannot desynchronize the stream.
///
/// [payloadLength] defaults to the current wire format; pass another value to
/// parse recordings made with a previous framing.
class PacketParser {
  final int payloadLength;

  PacketParser({this.payloadLength = TelemetryFraming.payloadLength});

  int get _totalPacketLength =>
      TelemetryFraming.startWordLength + payloadLength;

  final _buf = <int>[];

  /// Feed a raw byte chunk from the serial stream into the parser.
  ///
  /// Pass optional [timestampMs] when replaying recorded binary streams to preserve
  /// original arrival times. Defaults to [DateTime.now] for live streaming.
  ///
  /// Returns a list of all complete [TelemetryPacket]s extracted.
  List<TelemetryPacket> feed(Uint8List chunk, {int? timestampMs}) {
    _buf.addAll(chunk);
    final packets = <TelemetryPacket>[];

    while (_buf.length >= _totalPacketLength) {
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
      if (_buf.length < _totalPacketLength) break;

      // Extract payload bytes.
      final payload = Uint8List.fromList(
        _buf.sublist(
          TelemetryFraming.startWordLength,
          _totalPacketLength,
        ),
      );

      // Advance buffer past this packet.
      _buf.removeRange(0, _totalPacketLength);

      // Drop frames with a bad CRC.
      if (!FrameCodec.verifyCrc(payload)) continue;

      packets.add(
        TelemetryPacket(
          receivedAtMs: timestampMs ?? DateTime.now().millisecondsSinceEpoch,
          rawData: payload,
        ),
      );
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
