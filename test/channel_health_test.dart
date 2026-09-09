import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:serial/serial.dart';
import 'package:trycatch/src/telemetry/channel_health.dart';

Uint8List validPacket(int sequence) => FrameCodec.encodePacket(
      TelemetryFrame(sequence: sequence),
    );

void main() {
  group('PacketParser byte stats', () {
    test('counts matched bytes for a valid packet', () {
      final parser = PacketParser();
      parser.feed(validPacket(1));
      expect(parser.matchedPackets, 1);
      expect(parser.matchedBytes, TelemetryFraming.totalPacketLength);
      expect(parser.totalBytes, TelemetryFraming.totalPacketLength);
      expect(parser.unmatchedBytes, 0);
    });

    test('counts garbage bytes before the sync word', () {
      final parser = PacketParser();
      final garbage = Uint8List.fromList([0x12, 0x34, 0x56, 0xAA]);
      parser.feed(Uint8List.fromList([...garbage, ...validPacket(3)]));
      expect(parser.matchedPackets, 1);
      expect(parser.garbageBytes, garbage.length);
      expect(parser.unmatchedBytes, garbage.length);
      expect(parser.totalBytes,
          garbage.length + TelemetryFraming.totalPacketLength);
    });

    test('counts CRC-failed frames as unmatched', () {
      final parser = PacketParser();
      final bad = validPacket(9)..[10] ^= 0xFF;
      expect(parser.feed(bad), isEmpty);
      expect(parser.crcErrorCount, 1);
      expect(parser.crcErrorBytes, TelemetryFraming.totalPacketLength);
      expect(parser.unmatchedBytes, TelemetryFraming.totalPacketLength);
      expect(parser.matchedPackets, 0);
    });

    test('resetStats clears counters', () {
      final parser = PacketParser();
      parser.feed(Uint8List.fromList([0x00, ...validPacket(1)]));
      expect(parser.totalBytes, greaterThan(0));
      parser.resetStats();
      expect(parser.totalBytes, 0);
      expect(parser.matchedPackets, 0);
      expect(parser.unmatchedBytes, 0);
    });
  });

  group('ChannelHealthTracker', () {
    LinkStats snap(int t, int total, int matched, int packets,
            {int garbage = 0, int crcBytes = 0}) =>
        LinkStats(
          timestampMs: t,
          totalBytes: total,
          matchedBytes: matched,
          garbageBytes: garbage,
          crcErrorBytes: crcBytes,
          matchedPackets: packets,
        );

    test('baselines on first snapshot, then computes rates', () {
      final tracker = ChannelHealthTracker();
      expect(
          tracker.addSnapshot(snap(1000, 100, 55, 1, garbage: 45)), isNull);
      final sample =
          tracker.addSnapshot(snap(2000, 210, 110, 2, garbage: 100));
      expect(sample, isNotNull);
      expect(sample!.totalBps, 110.0);
      expect(sample.matchedBps, 55.0);
      // 55 matched of 110 total → 55 unmatched.
      expect(sample.unmatchedBps, 55.0);
      expect(sample.packetRate, 1.0);
    });

    test('foreign traffic shows up as unmatched rate', () {
      final tracker = ChannelHealthTracker();
      tracker.addSnapshot(snap(1000, 100, 55, 1, garbage: 45));
      // 1000 extra bytes arrived but nothing new matched.
      final sample =
          tracker.addSnapshot(snap(2000, 1100, 55, 1, garbage: 1045));
      expect(sample!.unmatchedBps, 1000.0);
      expect(sample.matchedBps, 0.0);
      expect(verdictFor(sample.unmatchedBps), ChannelVerdict.interference);
    });

    test('reset clears history on counter regression', () {
      final tracker = ChannelHealthTracker();
      tracker.addSnapshot(snap(1000, 100, 55, 1, garbage: 45));
      tracker.addSnapshot(snap(2000, 200, 110, 2, garbage: 90));
      expect(tracker.samples.length, 1);
      // Worker reconnected: counters restarted at zero.
      expect(tracker.addSnapshot(snap(3000, 10, 0, 0)), isNull);
      expect(tracker.samples, isEmpty);
    });

    test('verdict thresholds', () {
      expect(verdictFor(0), ChannelVerdict.clear);
      expect(verdictFor(49), ChannelVerdict.clear);
      expect(verdictFor(50), ChannelVerdict.activity);
      expect(verdictFor(399), ChannelVerdict.activity);
      expect(verdictFor(400), ChannelVerdict.interference);
    });
  });

  group('Mock interference', () {
    test('cycles clean → light → heavy every 20 s', () {
      expect(mockPhaseForTick(0), MockInterferencePhase.clean);
      expect(mockPhaseForTick(119), MockInterferencePhase.clean);
      expect(mockPhaseForTick(120), MockInterferencePhase.light);
      expect(mockPhaseForTick(159), MockInterferencePhase.light);
      expect(mockPhaseForTick(160), MockInterferencePhase.heavy);
      expect(mockPhaseForTick(199), MockInterferencePhase.heavy);
      expect(mockPhaseForTick(200), MockInterferencePhase.clean);
    });

    test('emits nothing when clean, noise otherwise', () {
      final random = math.Random(42);
      expect(mockInterferenceBytes(0, random), isNull);
      expect(mockInterferenceBytes(120, random)!.length, 15);
      expect(mockInterferenceBytes(160, random)!.length, 50);
    });

    test('mock noise decodes as unmatched bytes, never as packets', () {
      final random = math.Random(7);
      final parser = PacketParser();
      // A full heavy-phase second: 10 valid packets + 10 noise bursts.
      for (var tick = 160; tick < 170; tick++) {
        parser.feed(validPacket(tick));
        parser.feed(mockInterferenceBytes(tick, random)!);
      }
      // All 10 real packets still decode through the noise...
      expect(parser.matchedPackets, greaterThanOrEqualTo(10));
      expect(parser.matchedBytes,
          greaterThanOrEqualTo(10 * TelemetryFraming.totalPacketLength));
      // ...and the noise shows up as ~500 unmatched bytes.
      expect(parser.unmatchedBytes, greaterThan(400));
    });
  });

  group('buildChannelProfile', () {
    List<RecordingChunk> chunksWithGarbage() {
      const baseUs = 1700000000000000;
      final out = <RecordingChunk>[];
      for (var i = 0; i < 5; i++) {
        out.add(RecordingChunk(
          tsUs: baseUs + i * 100000,
          payload: validPacket(i),
        ));
      }
      // Trailing garbage chunk in the next bin (larger than one packet so
      // the parser can classify it instead of holding it as a partial).
      out.add(RecordingChunk(
        tsUs: baseUs + 500000,
        payload: Uint8List.fromList(List.filled(60, 0x31)),
      ));
      return out;
    }

    test('empty chunks yield no bins', () {
      expect(buildChannelProfile(const []), isEmpty);
    });

    test('buckets matched and unmatched bytes per bin', () {
      final profile = buildChannelProfile(chunksWithGarbage(), binMs: 500);
      expect(profile.length, 2);
      expect(profile[0].startMs, 0);
      expect(profile[0].matchedPackets, 5);
      expect(profile[0].matchedBytes, 5 * TelemetryFraming.totalPacketLength);
      expect(profile[0].unmatchedBytes, 0);
      expect(profile[1].unmatchedBytes, greaterThan(0));
      expect(profile[1].matchedPackets, 0);
      // Bins carry per-second rates over their width.
      expect(profile[0].matchedBps,
          5 * TelemetryFraming.totalPacketLength / 0.5);
    });
  });
}
