import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:serial/serial.dart';
import 'package:trycatch/flights/flight_trim.dart';

Future<Directory> _tempDir() =>
    Directory.systemTemp.createTemp('flight_trim_test');

/// Builds a fake v1 recording: header + 10 chunks, 1 s apart.
Future<String> _writeFake(String dir) async {
  final chunks = [
    for (var i = 0; i < 10; i++)
      RecordingChunk(
          tsUs: (1000 + i) * 1000000, payload: Uint8List.fromList([i])),
  ];
  final path = '$dir${Platform.pathSeparator}flight.bin';
  const header = RecordingHeader();
  await writeRecordingFile(path, header, chunks);
  return path;
}

void main() {
  group('flight_trim', () {
    test('round-trips chunks byte-identically', () async {
      final dir = await _tempDir();
      try {
        final path = await _writeFake(dir.path);
        final back = await readRecordingChunks(path);
        expect(back.length, 10);
        expect(back.first.tsMs, 1000000);
        expect(back.last.tsMs, 1009000);
        expect(back[4].payload, [4]);
      } finally {
        await dir.delete(recursive: true);
      }
    });

    test('trims a time slice relative to the first chunk', () async {
      final dir = await _tempDir();
      try {
        final src = await _writeFake(dir.path);
        final dst = '${dir.path}${Platform.pathSeparator}clip.bin';
        // First chunk is t=0 → keep chunks 2..5 (payloads [2..5]).
        final kept = await trimRecording(
          srcPath: src,
          dstPath: dst,
          startMs: 2000,
          endMs: 5000,
        );
        expect(kept, 4);
        final back = await readRecordingChunks(dst);
        expect([for (final c in back) c.payload.first], [2, 3, 4, 5]);
        // Original timestamps preserved.
        expect(back.first.tsMs, 1002000);
      } finally {
        await dir.delete(recursive: true);
      }
    });

    test('empty window writes nothing', () async {
      final dir = await _tempDir();
      try {
        final src = await _writeFake(dir.path);
        final dst = '${dir.path}${Platform.pathSeparator}clip.bin';
        final kept = await trimRecording(
          srcPath: src,
          dstPath: dst,
          startMs: 60000,
          endMs: 70000,
        );
        expect(kept, 0);
        expect(await File(dst).exists(), isFalse);
      } finally {
        await dir.delete(recursive: true);
      }
    });

    test('stops at corrupt headers', () async {
      final dir = await _tempDir();
      try {
        final path = '${dir.path}${Platform.pathSeparator}broken.bin';
        final file = File(path);
        final raf = await file.open(mode: FileMode.write);
        const header = RecordingHeader();
        await raf.writeFrom(header.encode());
        final chunkHeader = ByteData(12)
          ..setInt64(0, 1000000, Endian.big)
          ..setUint32(8, 1, Endian.big);
        await raf.writeFrom(chunkHeader.buffer.asUint8List());
        await raf.writeFrom(Uint8List.fromList([7]));
        // Garbage: absurd length.
        final bad = ByteData(12)
          ..setInt64(0, 2000000, Endian.big)
          ..setUint32(8, 0xFFFFFFFF, Endian.big);
        await raf.writeFrom(bad.buffer.asUint8List());
        await raf.close();
        final back = await readRecordingChunks(path);
        expect(back.length, 1);
      } finally {
        await dir.delete(recursive: true);
      }
    });

    test('decodeRecordingFrames reassembles fragmented raw streams', () async {
      final dir = await _tempDir();
      try {
        // 20 real packets with rising altitude + drifting fix.
        final stream = <int>[0x00, 0xFF, 0x00]; // line noise
        for (var i = 0; i < 20; i++) {
          final frame = TelemetryFrame(
            sequence: i,
            flags: FrameFlags.gpsFix | FrameFlags.gpsFix3d,
            latitude: 50.0 + i * 0.0001,
            longitude: 14.0 + i * 0.0001,
            gpsAltitude: 200 + i * 10.0,
            baroAltitude: i * 10.0,
          );
          stream.addAll(FrameCodec.encodePacket(frame));
        }
        // Split into awkward fragments (sync words split mid-way).
        var pos = 0;
        var frag = 0;
        const sizes = [7, 1, 64, 3, 100, 13, 55];
        final chunks = <RecordingChunk>[];
        while (pos < stream.length) {
          final n = sizes[frag % sizes.length];
          final end = (pos + n).clamp(0, stream.length);
          chunks.add(RecordingChunk(
            tsUs: (2000 + frag) * 1000000,
            payload:
                Uint8List.fromList(stream.sublist(pos, end)),
          ));
          pos = end;
          frag++;
        }
        final path = '${dir.path}${Platform.pathSeparator}raw.bin';
        await writeRecordingChunks(path, chunks);
        // Bodies gain their header via finalize (as the recorder does).
        await finalizeRecordingFile(path);

        // Decoding raw chunks directly yields nothing (they are stream
        // fragments, not packets) — the preview must go via the parser.
        expect(
          chunks.any((c) =>
              FrameCodec.decode(c.payload, receivedAtMs: 0) != null),
          isFalse,
        );

        final flight = await decodeRecordingFrames(path);
        expect(flight.frames.length, 20);
        expect(flight.frames.first.baroAltitude, 0);
        expect(flight.frames.last.baroAltitude, 190);
        expect(
          flight.frames.last.receivedAtMs - flight.frames.first.receivedAtMs,
          greaterThanOrEqualTo(0),
        );
        expect(buildAltProfile(flight.frames).length, 20);
        final track = buildTrackProfile(flight.frames);
        expect(track.length, 20);
        expect(track.last.lat, greaterThan(track.first.lat));
      } finally {
        await dir.delete(recursive: true);
      }
    });

    test('track profile keeps fixes only', () {
      final frames = [
        const TelemetryFrame(flags: FrameFlags.gpsFix, baroAltitude: 1),
        const TelemetryFrame(baroAltitude: 2),
        const TelemetryFrame(flags: FrameFlags.gpsFix, baroAltitude: 3),
      ];
      expect(buildAltProfile(frames), [1, 2, 3]);
      expect(buildTrackProfile(frames).length, 2);
    });
  });
}
