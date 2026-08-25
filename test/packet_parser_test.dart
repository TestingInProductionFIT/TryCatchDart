import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:serial/serial.dart';

void main() {
  group('PacketParser', () {
    late PacketParser parser;

    setUp(() {
      parser = PacketParser();
    });

    test('parses a single packet correctly', () {
      final data = Uint8List(TelemetryFraming.totalPacketLength);
      data[0] = TelemetryFraming.startByte0;
      data[1] = TelemetryFraming.startByte1;
      for (var i = TelemetryFraming.startWordLength;
          i < TelemetryFraming.totalPacketLength;
          i++) {
        data[i] = i;
      }

      final packets = parser.feed(data);
      expect(packets.length, 1);
      expect(packets.first.rawData.length, TelemetryFraming.payloadLength);
      expect(packets.first.rawData[0], 2);
      expect(packets.first.rawData[30], 32);
    });

    test('handles garbage bytes before start word', () {
      final garbage = Uint8List.fromList([0x12, 0x34, 0x56, 0xAA]); // AA without 55
      final valid = Uint8List(33);
      valid[0] = 0xAA;
      valid[1] = 0x55;
      for (var i = 2; i < 33; i++) {
        valid[i] = 0xFF;
      }

      final combined = Uint8List.fromList([...garbage, ...valid]);
      final packets = parser.feed(combined);

      expect(packets.length, 1);
      expect(packets.first.rawData.length, 31);
      expect(packets.first.rawData.every((b) => b == 0xFF), isTrue);
    });

    test('handles packets split across multiple chunks', () {
      final fullPacket = Uint8List(33);
      fullPacket[0] = 0xAA;
      fullPacket[1] = 0x55;
      for (var i = 2; i < 33; i++) {
        fullPacket[i] = i * 2;
      }

      final chunk1 = Uint8List.sublistView(fullPacket, 0, 10);
      final chunk2 = Uint8List.sublistView(fullPacket, 10, 25);
      final chunk3 = Uint8List.sublistView(fullPacket, 25, 33);

      expect(parser.feed(chunk1), isEmpty);
      expect(parser.feed(chunk2), isEmpty);
      final packets = parser.feed(chunk3);

      expect(packets.length, 1);
      expect(packets.first.rawData.length, 31);
      expect(packets.first.rawData[0], 4);
    });

    test('handles multiple packets in a single chunk', () {
      final packet1 = Uint8List(33);
      packet1[0] = 0xAA;
      packet1[1] = 0x55;
      packet1[2] = 0x01;

      final packet2 = Uint8List(33);
      packet2[0] = 0xAA;
      packet2[1] = 0x55;
      packet2[2] = 0x02;

      final combined = Uint8List.fromList([...packet1, ...packet2]);
      final packets = parser.feed(combined);

      expect(packets.length, 2);
      expect(packets[0].rawData[0], 0x01);
      expect(packets[1].rawData[0], 0x02);
    });
  });
}
