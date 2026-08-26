import 'dart:io';
import 'dart:typed_data';

import '../worker/protocol.dart';
import 'packet_parser.dart';

/// Handles reading and decoding framed binary recording files.
class FileParser {
  /// Reads framed binary data from [filePath] and yields parsed [TelemetryPacket]s using [parser].
  ///
  /// Sequential chunk-by-chunk stream processing ensures low RAM usage when parsing large logs,
  /// preserving historical chunk arrival timestamps for each reconstructed packet.
  Stream<TelemetryPacket> parseFile(
    String filePath,
    PacketParser parser,
  ) async* {
    final file = File(filePath);
    final reader = await file.open(mode: FileMode.read);

    try {
      final fileLength = await reader.length();

      while (await reader.position() < fileLength) {
        // Read 12-byte header: Int64 timestamp (bytes 0-7), Uint32 length (bytes 8-11)
        final headerBytes = await reader.read(12);
        if (headerBytes.length < 12) break;

        final header = ByteData.sublistView(headerBytes);
        final timestampMicros = header.getInt64(0, Endian.big);
        final payloadLength = header.getUint32(8, Endian.big);

        // Read raw chunk payload
        final chunk = await reader.read(payloadLength);
        final timestampMs = timestampMicros ~/ 1000;

        // Feed chunk into parser using historical chunk arrival timestamp
        final packets = parser.feed(chunk, timestampMs: timestampMs);
        for (final packet in packets) {
          yield packet;
        }
      }
    } finally {
      await reader.close();
    }
  }
}
