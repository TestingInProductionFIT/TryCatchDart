import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:serial/serial.dart';

void main() {
  group('FileParser', () {
    late Directory tempDir;
    late String testFilePath;
    late FileParser fileParser;
    late PacketParser packetParser;
    late Recorder recorder;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp(
        'trycatch_file_parser_test_',
      );
      testFilePath =
          '${tempDir.path}${Platform.pathSeparator}test_recording.bin';
      fileParser = FileParser();
      packetParser = PacketParser();
      recorder = Recorder();
    });

    tearDown(() async {
      await recorder.stop();
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    Uint8List createTelemetryPacketData(int payloadByte) {
      final data = Uint8List(TelemetryFraming.totalPacketLength);
      data[0] = TelemetryFraming.startByte0;
      data[1] = TelemetryFraming.startByte1;
      for (
        var i = TelemetryFraming.startWordLength;
        i < TelemetryFraming.totalPacketLength;
        i++
      ) {
        data[i] = payloadByte;
      }
      return data;
    }

    test('parses telemetry packets from recorder binary file', () async {
      await recorder.start(testFilePath);

      final packetData = createTelemetryPacketData(0x42);
      recorder.recordBytes(packetData);
      await recorder.stop();

      final packets = await fileParser
          .parseFile(testFilePath, packetParser)
          .toList();

      expect(packets.length, 1);
      expect(packets.first.rawData.length, TelemetryFraming.payloadLength);
      expect(packets.first.rawData[0], 0x42);
    });

    test('correctly converts microsecond timestamps to milliseconds', () async {
      final file = File(testFilePath);
      await file.parent.create(recursive: true);

      const timestampMicros = 1700000000000000;
      const expectedMs = 1700000000000;

      final packetData = createTelemetryPacketData(0x99);

      final header = ByteData(12)
        ..setInt64(0, timestampMicros, Endian.big)
        ..setUint32(8, packetData.length, Endian.big);

      final builder = BytesBuilder()
        ..add(header.buffer.asUint8List())
        ..add(packetData);

      await file.writeAsBytes(builder.toBytes());

      final packets = await fileParser
          .parseFile(testFilePath, packetParser)
          .toList();

      expect(packets.length, 1);
      expect(packets.first.receivedAtMs, expectedMs);
      expect(packets.first.rawData[0], 0x99);
    });

    test('handles packet split across multiple framed chunks', () async {
      final fullPacket = createTelemetryPacketData(0x07);

      final chunk1 = Uint8List.sublistView(fullPacket, 0, 10);
      final chunk2 = Uint8List.sublistView(fullPacket, 10, fullPacket.length);

      final file = File(testFilePath);
      await file.parent.create(recursive: true);

      const timestampMicros1 = 1700000001000000;
      const timestampMicros2 = 1700000005000000;
      const expectedMs2 = 1700000005000;

      final frame1 = ByteData(12)
        ..setInt64(0, timestampMicros1, Endian.big)
        ..setUint32(8, chunk1.length, Endian.big);

      final frame2 = ByteData(12)
        ..setInt64(0, timestampMicros2, Endian.big)
        ..setUint32(8, chunk2.length, Endian.big);

      final builder = BytesBuilder()
        ..add(frame1.buffer.asUint8List())
        ..add(chunk1)
        ..add(frame2.buffer.asUint8List())
        ..add(chunk2);

      await file.writeAsBytes(builder.toBytes());

      final packets = await fileParser
          .parseFile(testFilePath, packetParser)
          .toList();

      expect(packets.length, 1);
      expect(packets.first.receivedAtMs, expectedMs2);
      expect(packets.first.rawData[0], 0x07);
    });

    test('yields empty stream for an empty recording file', () async {
      final file = File(testFilePath);
      await file.create(recursive: true);

      final packets = await fileParser
          .parseFile(testFilePath, packetParser)
          .toList();

      expect(packets, isEmpty);
    });
  });
}
