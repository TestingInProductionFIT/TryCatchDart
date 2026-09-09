import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:serial/serial.dart';

void main() {
  group('Recorder', () {
    late Directory tempDir;
    late String testFilePath;
    late Recorder recorder;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('trycatch_rec_test_');
      testFilePath = '${tempDir.path}${Platform.pathSeparator}test_dump.bin';
      recorder = Recorder();
    });

    tearDown(() async {
      await recorder.stop();
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    test('records framed binary data with 12-byte headers per chunk', () async {
      final beforeMicros = DateTime.now().microsecondsSinceEpoch;

      await recorder.start(testFilePath);
      expect(recorder.isRecording, isTrue);

      final chunk1 = Uint8List.fromList([
        0xDE,
        0xAD,
        0xBE,
        0xEF,
      ]); // Garbage preamble
      final chunk2 = Uint8List.fromList([
        0xAA,
        0x55,
        0x01,
        0x02,
      ]); // Partial packet
      final chunk3 = Uint8List.fromList([0x03, 0x04]);

      recorder.recordBytes(chunk1);
      recorder.recordBytes(chunk2);
      recorder.recordBytes(chunk3);

      // 3 chunks * 12-byte header + (4 + 4 + 2) payload bytes = 46 bytes
      // of body; stop() prepends the 112-byte file header (garbage chunks
      // decode to nothing, so the header carries zero stats).
      expect(recorder.bytesWritten, 46);

      await recorder.stop();
      expect(recorder.isRecording, isFalse);

      final afterMicros = DateTime.now().microsecondsSinceEpoch;

      final file = File(testFilePath);
      expect(await file.exists(), isTrue);

      final savedBytes = await file.readAsBytes();
      expect(savedBytes.length, 112 + 46);

      // Verify file header.
      final fileHeader =
          RecordingHeader.decode(savedBytes.sublist(0, 112))!;
      expect(fileHeader.hasStats, isTrue);
      expect(fileHeader.hasLaunchSite, isFalse);
      expect(fileHeader.packetCount, 0);
      expect(fileHeader.payloadLength, 0);

      // Verify Frame 1 (body starts past the 112-byte file header).
      var offset = 112;
      var header1 = ByteData.sublistView(savedBytes, offset, offset + 12);
      var ts1 = header1.getInt64(0, Endian.big);
      var len1 = header1.getUint32(8, Endian.big);
      expect(ts1, greaterThanOrEqualTo(beforeMicros));
      expect(ts1, lessThanOrEqualTo(afterMicros));
      expect(len1, 4);
      expect(savedBytes.sublist(offset + 12, offset + 12 + len1), chunk1);

      // Verify Frame 2
      offset += 12 + len1;
      var header2 = ByteData.sublistView(savedBytes, offset, offset + 12);
      var ts2 = header2.getInt64(0, Endian.big);
      var len2 = header2.getUint32(8, Endian.big);
      expect(ts2, greaterThanOrEqualTo(ts1));
      expect(ts2, lessThanOrEqualTo(afterMicros));
      expect(len2, 4);
      expect(savedBytes.sublist(offset + 12, offset + 12 + len2), chunk2);

      // Verify Frame 3
      offset += 12 + len2;
      var header3 = ByteData.sublistView(savedBytes, offset, offset + 12);
      var ts3 = header3.getInt64(0, Endian.big);
      var len3 = header3.getUint32(8, Endian.big);
      expect(ts3, greaterThanOrEqualTo(ts2));
      expect(ts3, lessThanOrEqualTo(afterMicros));
      expect(len3, 2);
      expect(savedBytes.sublist(offset + 12, offset + 12 + len3), chunk3);
    });

    test('ignores empty byte chunks', () async {
      await recorder.start(testFilePath);
      recorder.recordBytes(Uint8List(0));
      expect(recorder.bytesWritten, 0);
      await recorder.stop();

      final file = File(testFilePath);
      expect(await file.readAsBytes(), isEmpty);
    });
  });
}
