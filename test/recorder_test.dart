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

    test('records exact 1:1 raw binary data including garbage/incomplete chunks', () async {
      await recorder.start(testFilePath);
      expect(recorder.isRecording, isTrue);

      final chunk1 = Uint8List.fromList([0xDE, 0xAD, 0xBE, 0xEF]); // Garbage preamble
      final chunk2 = Uint8List.fromList([0xAA, 0x55, 0x01, 0x02]); // Partial packet
      final chunk3 = Uint8List.fromList([0x03, 0x04]);

      recorder.recordBytes(chunk1);
      recorder.recordBytes(chunk2);
      recorder.recordBytes(chunk3);

      expect(recorder.bytesWritten, 10);

      await recorder.stop();
      expect(recorder.isRecording, isFalse);

      final file = File(testFilePath);
      expect(await file.exists(), isTrue);

      final savedBytes = await file.readAsBytes();
      expect(savedBytes, [0xDE, 0xAD, 0xBE, 0xEF, 0xAA, 0x55, 0x01, 0x02, 0x03, 0x04]);
    });
  });
}
