import 'dart:io';
import 'dart:typed_data';

import '../constants.dart';
import '../worker/protocol.dart';
import 'packet_parser.dart';
import 'recording_file.dart';

/// Handles reading and decoding recording files.
///
/// The file must open with a valid [RecordingHeader] whose framing matches
/// [TelemetryFraming.payloadLength]. Files without a valid header yield no
/// packets.
class FileParser {
  /// Reads framed binary data from [filePath] and yields parsed [TelemetryPacket]s.
  ///
  /// Sequential chunk-by-chunk stream processing ensures low RAM usage when parsing large logs,
  /// preserving historical chunk arrival timestamps for each reconstructed packet.
  Stream<TelemetryPacket> parseFile(String filePath) async* {
    final file = File(filePath);
    final reader = await file.open(mode: FileMode.read);

    try {
      final fileLength = await reader.length();
      if (fileLength < recordingHeaderLength) return;
      final header =
          RecordingHeader.decode(await reader.read(recordingHeaderLength));
      if (header == null ||
          header.payloadLength != TelemetryFraming.payloadLength) {
        return;
      }
      final parser = PacketParser();

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
