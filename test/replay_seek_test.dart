import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:serial/serial.dart';
import 'package:trycatch/state/replay_controller.dart';
import 'package:trycatch/state/telemetry_provider.dart';
import 'package:trycatch/state/telemetry_store.dart';

/// Regression test: seeking a large recording must be cheap and exact.
/// The old implementation replayed 0→target with per-packet state churn on
/// every slider tick (26k provider rebuilds per scrub on a full flight log).
/// The new one binary-searches the target and ingests forward deltas only.
void main() {
  group('ReplayController.seek', () {
    late Directory tempDir;
    late String path;
    late ProviderContainer container;

    const packetCount = 200;
    const stepUs = 40000;
    const baseUs = 1700000000000000;

    int tsUs(int i) => baseUs + i * stepUs;

    Future<void> writeRecording() async {
      final builder = BytesBuilder()
        ..add(const RecordingHeader(
          payloadLength: TelemetryFraming.payloadLength,
          hasLaunchSite: true,
          hasStats: true,
          launchLatitude: 49.799,
          launchLongitude: 16.693,
          launchMslM: 403,
          launchName: 'Pad',
        ).encode());
      for (var i = 0; i < packetCount; i++) {
        final packet = FrameCodec.encodePacket(
          TelemetryFrame(sequence: i, baroAltitude: i.toDouble()),
        );
        builder.add((ByteData(12)
              ..setInt64(0, tsUs(i), Endian.big)
              ..setUint32(8, packet.length, Endian.big))
            .buffer
            .asUint8List());
        builder.add(packet);
      }
      await File(path).writeAsBytes(builder.toBytes());
    }

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('trycatch_seek_test_');
      path =
          '${tempDir.path}${Platform.pathSeparator}seek_recording.bin';
      await writeRecording();
      container = ProviderContainer(overrides: [
        telemetryStreamProvider
            .overrideWith((ref) => Stream<TelemetryPacket>.empty()),
        serialStatusProvider.overrideWith(
            (ref) => Stream.value(const SerialWorkerStatus())),
      ]);
      addTearDown(container.dispose);
    });

    tearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    TelemetryState storeState() =>
        container.read(telemetryStoreProvider);

    Future<ReplayController> loadAndPark() async {
      final controller = container.read(replayProvider.notifier);
      await controller.play(path);
      controller.pause();
      controller.seek(0);
      return controller;
    }

    test('loads all frames and parks at zero (incl. the t=0 packet)',
        () async {
      final controller = await loadAndPark();
      expect(container.read(replayProvider).frames.length, packetCount);
      // positionMs 0 still contains the packet stamped exactly at start.
      expect(storeState().history.length, 1);
      expect(storeState().latest!.sequence, 0);
      expect(storeState().packetCount, 1);
      expect(controller.debugIndex, 1);
    });

    test('direct, forward and backward seeks agree exactly', () async {
      final controller = await loadAndPark();

      int relMs(int i) => (tsUs(i) - baseUs) ~/ 1000;

      controller.seek(relMs(100));
      expect(storeState().history.length, 101);
      expect(storeState().latest!.sequence, 100);
      expect(storeState().packetCount, 101);
      expect(controller.debugIndex, 101);

      // Small forward step ingests only the delta.
      controller.seek(relMs(102));
      expect(storeState().history.length, 103);
      expect(storeState().latest!.sequence, 102);
      expect(storeState().packetCount, 103);

      // Backward jump replays from the start with the same result.
      controller.seek(relMs(50));
      expect(storeState().history.length, 51);
      expect(storeState().latest!.sequence, 50);
      expect(storeState().packetCount, 51);

      // Past-the-end parks at the final frame.
      controller.seek(relMs(packetCount) + 100000);
      expect(storeState().history.length, packetCount);
      expect(storeState().latest!.sequence, packetCount - 1);
    });

    test('smoothing flag defaults off, toggles, and survives reload',
        () async {
      final controller = await loadAndPark();
      expect(container.read(replayProvider).smoothingEnabled, isFalse);
      controller.setSmoothing(true);
      expect(container.read(replayProvider).smoothingEnabled, isTrue);
      await controller.play(path);
      controller.pause();
      expect(container.read(replayProvider).smoothingEnabled, isTrue);
    });

    test('transport toggle flips actual playback and never strands it',
        () async {
      final controller = await loadAndPark();
      expect(container.read(replayProvider).playing, isFalse);

      controller.toggle();
      expect(container.read(replayProvider).playing, isTrue);

      // A second resume is idempotent, not a second ticker.
      controller.resume();
      expect(container.read(replayProvider).playing, isTrue);

      controller.toggle();
      expect(container.read(replayProvider).playing, isFalse);

      // Pausing twice is harmless; toggle still recovers to playing.
      controller.pause();
      controller.toggle();
      expect(container.read(replayProvider).playing, isTrue);
      controller.pause();
    });
  });
}
