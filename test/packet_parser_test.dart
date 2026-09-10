import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:serial/serial.dart';

/// Builds a wire-valid framed packet carrying [sequence].
Uint8List validPacket(int sequence) => FrameCodec.encodePacket(
      TelemetryFrame(sequence: sequence),
    );

void main() {
  group('PacketParser', () {
    late PacketParser parser;

    setUp(() {
      parser = PacketParser();
    });

    test('parses a single packet correctly with custom timestamp', () {
      const customTimestamp = 1700000000000;
      final packets =
          parser.feed(validPacket(7), timestampMs: customTimestamp);

      expect(packets.length, 1);
      expect(packets.first.receivedAtMs, customTimestamp);
      expect(packets.first.rawData.length, TelemetryFraming.payloadLength);

      final frame =
          FrameCodec.decode(packets.first.rawData, receivedAtMs: 0)!;
      expect(frame.sequence, 7);
    });

    test('defaults to current timestamp when timestampMs is omitted', () {
      final before = DateTime.now().millisecondsSinceEpoch;
      final packets = parser.feed(validPacket(1));
      final after = DateTime.now().millisecondsSinceEpoch;

      expect(packets.length, 1);
      expect(packets.first.receivedAtMs, greaterThanOrEqualTo(before));
      expect(packets.first.receivedAtMs, lessThanOrEqualTo(after));
    });

    test('handles garbage bytes before start word', () {
      final garbage =
          Uint8List.fromList([0x12, 0x34, 0x56, 0xAA]); // AA without 55

      const customTimestamp = 1700000000000;
      final combined = Uint8List.fromList([...garbage, ...validPacket(3)]);
      final packets = parser.feed(combined, timestampMs: customTimestamp);

      expect(packets.length, 1);
      final frame =
          FrameCodec.decode(packets.first.rawData, receivedAtMs: 0)!;
      expect(frame.sequence, 3);
    });

    test('drops a packet with a corrupted payload CRC', () {
      final packet = validPacket(9);
      packet[10] ^= 0xFF; // corrupt inside the payload → CRC mismatch

      final packets = parser.feed(packet, timestampMs: 0);
      expect(packets, isEmpty);
    });

    test('resynchronizes after a corrupted packet', () {
      final bad = validPacket(1)..[20] ^= 0xFF;
      final good = validPacket(2);
      final combined = Uint8List.fromList([...bad, ...good]);

      final packets = parser.feed(combined, timestampMs: 0);
      expect(packets.length, 1);
      final frame =
          FrameCodec.decode(packets.first.rawData, receivedAtMs: 0)!;
      expect(frame.sequence, 2);
    });

    test('handles packets split across multiple chunks', () {
      final fullPacket = validPacket(4);

      final chunk1 = Uint8List.sublistView(fullPacket, 0, 10);
      final chunk2 = Uint8List.sublistView(fullPacket, 10, 25);
      final chunk3 =
          Uint8List.sublistView(fullPacket, 25, fullPacket.length);

      const completionTimestamp = 1700000005000;

      expect(parser.feed(chunk1, timestampMs: 1700000001000), isEmpty);
      expect(parser.feed(chunk2, timestampMs: 1700000003000), isEmpty);
      final packets = parser.feed(chunk3, timestampMs: completionTimestamp);

      expect(packets.length, 1);
      expect(packets.first.receivedAtMs, completionTimestamp);
      final frame =
          FrameCodec.decode(packets.first.rawData, receivedAtMs: 0)!;
      expect(frame.sequence, 4);
    });

    test('handles multiple packets in a single chunk with shared timestamp', () {
      const customTimestamp = 1700000000000;
      final combined =
          Uint8List.fromList([...validPacket(1), ...validPacket(2)]);
      final packets = parser.feed(combined, timestampMs: customTimestamp);

      expect(packets.length, 2);
      expect(packets[0].receivedAtMs, customTimestamp);
      expect(packets[1].receivedAtMs, customTimestamp);

      final f1 = FrameCodec.decode(packets[0].rawData, receivedAtMs: 0)!;
      final f2 = FrameCodec.decode(packets[1].rawData, receivedAtMs: 0)!;
      expect(f1.sequence, 1);
      expect(f2.sequence, 2);
    });
  });
}
