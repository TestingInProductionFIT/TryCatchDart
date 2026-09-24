import 'dart:io';
import 'dart:typed_data';

import '../connectors/connector.dart';
import '../telemetry/telemetry_frame.dart';
import 'recording_file.dart';

/// Handles reading and decoding recording files.
///
/// The file must open with a valid v3 [RecordingHeader]. Files without a
/// valid header (including v1/v2 recordings) yield no frames. Only the
/// header's telemetry section is decoded — the trailing command log is
/// never fed to the telemetry parser (use [readRecordingCommands] for it).
class FileParser {
  /// Reads framed binary data from [filePath] and yields internal
  /// [TelemetryFrame]s decoded with [connector].
  ///
  /// Sequential chunk-by-chunk stream processing ensures low RAM usage when parsing large logs,
  /// preserving historical chunk arrival timestamps for each reconstructed frame.
  Stream<TelemetryFrame> parseFile(
    String filePath, {
    required TelemetryConnector connector,
  }) async* {
    final file = File(filePath);
    final reader = await file.open(mode: FileMode.read);

    try {
      final fileLength = await reader.length();
      if (fileLength < recordingHeaderLength) return;
      final fileHeader =
          RecordingHeader.decode(await reader.read(recordingHeaderLength));
      if (fileHeader == null) {
        return;
      }
      // Bound decoding to the telemetry section so the trailing command
      // log is never mistaken for stream bytes. Provisional headers
      // (telemetryByteLen == 0, no commands) decode to EOF as before.
      var telemetryEnd = fileLength;
      if (fileHeader.telemetryByteLen > 0) {
        telemetryEnd = (recordingHeaderLength + fileHeader.telemetryByteLen)
            .clamp(recordingHeaderLength, fileLength);
      } else if (fileHeader.commandCount > 0) {
        telemetryEnd = fileHeader.commandsOffset
            .clamp(recordingHeaderLength, fileLength);
      }
      final parser = connector.createParser();

      while (await reader.position() < telemetryEnd) {
        // Read 12-byte header: Int64 timestamp (bytes 0-7), Uint32 length (bytes 8-11)
        final headerBytes = await reader.read(12);
        if (headerBytes.length < 12) break;

        final header = ByteData.sublistView(headerBytes);
        final timestampMicros = header.getInt64(0, Endian.big);
        final payloadLength = header.getUint32(8, Endian.big);

        // Read raw chunk payload
        final chunk = await reader.read(payloadLength);
        final timestampMs = timestampMicros ~/ 1000;

        // Feed chunk into the connector parser using the historical chunk
        // arrival timestamp
        for (final frame in parser.feed(chunk, timestampMs: timestampMs)) {
          yield frame;
        }
      }
    } finally {
      await reader.close();
    }
  }
}
