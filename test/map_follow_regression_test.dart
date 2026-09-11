import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:serial/serial.dart' show FrameFlags, TelemetryFrame;
import 'package:trycatch/core/dead_reckoning.dart';
import 'package:trycatch/core/ring_buffer.dart';
import 'package:trycatch/state/replay_controller.dart';
import 'package:trycatch/state/telemetry_store.dart';
import 'package:trycatch/ui/tiles/map_tile.dart';

/// Regression test for: open app, start playback, go to default replay
/// screen → `Exception: You need to have the FlutterMap widget rendered at
/// least once before using the MapController`, thrown building MapTile.
///
/// Root cause: follow-mode called `_mapController.camera` synchronously in
/// `build()`. When the tile mounts while a GPS fix is already present
/// (playback running), the first build touches the controller before
/// FlutterMap's first frame.
class _GpsFixStore extends TelemetryStore {
  @override
  TelemetryState build() {
    final history = RingBuffer<TelemetryFrame>(10);
    const frame = TelemetryFrame(
      sequence: 1,
      flags: FrameFlags.gpsFix,
      latitude: 50.0755,
      longitude: 14.4378,
    );
    history.push(frame);
    return TelemetryState(
      history: history,
      deadReckoningHistory: RingBuffer<DrPosition>(10),
      latest: frame,
      // Replay screen: dead reckoning hidden, follow path still active.
      replaying: true,
    );
  }
}

void main() {
  testWidgets(
      'map tile mounts with GPS fix already present without throwing',
      (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          telemetryStoreProvider.overrideWith(_GpsFixStore.new),
          effectiveLaunchSiteProvider.overrideWith((ref) => null),
        ],
        child: const MaterialApp(
          home: Scaffold(
            body: SizedBox(width: 800, height: 600, child: MapTile()),
          ),
        ),
      ),
    );
    // First build: GPS fix present, FlutterMap never rendered → used to throw.
    await tester.pump();
    expect(tester.takeException(), isNull);

    // Let onMapReady fire and post-frame follow moves run.
    await tester.pump(const Duration(milliseconds: 100));
    expect(tester.takeException(), isNull);
    await tester.pump(const Duration(milliseconds: 100));
    expect(tester.takeException(), isNull);

    expect(find.byType(MapTile), findsOneWidget);
  });
}
