import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:serial/serial.dart';

void main() {
  group('FileParser', () {
    late Directory tempDir;
    late String testFilePath;
    late FileParser fileParser;
    late Recorder recorder;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp(
        'trycatch_file_parser_test_',
      );
      testFilePath =
          '${tempDir.path}${Platform.pathSeparator}test_recording.bin';
      fileParser = FileParser();
      recorder = Recorder();
    });

    tearDown(() async {
      await recorder.stop();
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    /// Builds a wire-valid framed packet carrying [sequence].
    Uint8List createTelemetryPacket(int sequence) =>
        FrameCodec.encodePacket(TelemetryFrame(sequence: sequence));

    /// Wraps raw chunk bodies in a recording file: header + chunk framings.
    Future<void> writeHeaderedFile(
      String path,
      List<(int, Uint8List)> chunks,
    ) async {
      final file = File(path);
      await file.parent.create(recursive: true);
      const header = RecordingHeader(
          payloadLength: TelemetryFraming.payloadLength, hasStats: true);
      final builder = BytesBuilder()..add(header.encode());
      for (final (tsUs, payload) in chunks) {
        builder.add((ByteData(12)
              ..setInt64(0, tsUs, Endian.big)
              ..setUint32(8, payload.length, Endian.big))
            .buffer
            .asUint8List());
        builder.add(payload);
      }
      await file.writeAsBytes(builder.toBytes());
    }

    test('parses telemetry packets from recorder binary file', () async {
      await recorder.start(
        testFilePath,
        launch: const LaunchRef(
          latitude: 50.0,
          longitude: 14.0,
          mslM: 300,
          name: 'Test pad',
        ),
      );

      recorder.recordBytes(createTelemetryPacket(0x42));
      await recorder.stop();

      final packets = await fileParser.parseFile(testFilePath).toList();

      expect(packets.length, 1);
      expect(packets.first.rawData.length, TelemetryFraming.payloadLength);
      expect(
        FrameCodec.decode(packets.first.rawData, receivedAtMs: 0)!.sequence,
        0x42,
      );
    });

    test('correctly converts microsecond timestamps to milliseconds',
        () async {
      const timestampMicros = 1700000000000000;
      const expectedMs = 1700000000000;

      await writeHeaderedFile(testFilePath, [
        (timestampMicros, createTelemetryPacket(0x99)),
      ]);

      final packets = await fileParser.parseFile(testFilePath).toList();

      expect(packets.length, 1);
      expect(packets.first.receivedAtMs, expectedMs);
      expect(
        FrameCodec.decode(packets.first.rawData, receivedAtMs: 0)!.sequence,
        0x99,
      );
    });

    test('handles packet split across multiple framed chunks', () async {
      final fullPacket = createTelemetryPacket(0x07);

      final chunk1 = Uint8List.sublistView(fullPacket, 0, 10);
      final chunk2 = Uint8List.sublistView(fullPacket, 10, fullPacket.length);

      const timestampMicros1 = 1700000001000000;
      const timestampMicros2 = 1700000005000000;
      const expectedMs2 = 1700000005000;

      await writeHeaderedFile(testFilePath, [
        (timestampMicros1, chunk1),
        (timestampMicros2, chunk2),
      ]);

      final packets = await fileParser.parseFile(testFilePath).toList();

      expect(packets.length, 1);
      expect(packets.first.receivedAtMs, expectedMs2);
      expect(
        FrameCodec.decode(packets.first.rawData, receivedAtMs: 0)!.sequence,
        0x07,
      );
    });

    test('yields empty stream for an empty recording file', () async {
      final file = File(testFilePath);
      await file.create(recursive: true);

      final packets = await fileParser.parseFile(testFilePath).toList();

      expect(packets, isEmpty);
    });

    test('rejects files without a header, even with valid packets inside',
        () async {
      final file = File(testFilePath);
      await file.parent.create(recursive: true);
      final packet = createTelemetryPacket(0x07);
      final chunkHeader = ByteData(12)
        ..setInt64(0, 1700000000000000, Endian.big)
        ..setUint32(8, packet.length, Endian.big);
      await file.writeAsBytes([
        ...chunkHeader.buffer.asUint8List(),
        ...packet,
      ]);

      expect(await fileParser.parseFile(testFilePath).toList(), isEmpty);
    });
  });
}
