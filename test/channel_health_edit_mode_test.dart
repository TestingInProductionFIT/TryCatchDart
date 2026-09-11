import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:serial/serial.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:trycatch/state/telemetry_provider.dart';
import 'package:trycatch/ui/screens/dashboard_screen.dart';

/// Regression test: the channel-health tile used to reset every time edit
/// mode was entered/exited, while every other tile kept its data.
///
/// Root cause: the tile owned a private `ChannelHealthTracker` in its
/// `State`, fed once-per-snapshot from `linkStatsStreamProvider`. Toggling
/// edit mode swaps `AbsorbPointer`/`GestureDetector` wrappers around every
/// tile, which unmounts the tile `State` and discarded all accumulated
/// samples. Other tiles re-render from global providers, so only the
/// channel tile visibly reset. The history now lives in the shared
/// `channelHealthProvider`, so remounts are lossless.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('channel tile keeps its history across edit-mode toggles',
      (tester) async {
    SharedPreferences.setMockInitialValues({
      'trycatch.workspaces': jsonEncode({
        'activeId': 'ws1',
        'workspaces': [
          {
            'id': 'ws1',
            'name': 'Flight view',
            'root': {
              'type': 'leaf',
              'tileId': 't1',
              'tileType': 'channel_health',
            },
          },
        ],
      }),
    });

    final linkStats = StreamController<LinkStats>();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          serialStatusProvider.overrideWith(
              (ref) => Stream.value(const SerialWorkerStatus(
                    isConnected: true,
                    connectedPort: 'MOCK',
                  ))),
          linkStatsStreamProvider.overrideWith((ref) => linkStats.stream),
        ],
        child: const MaterialApp(home: Scaffold(body: DashboardScreen())),
      ),
    );
    await tester.pump();
    await tester.pump();

    // Two snapshots baseline the tracker, then yield one 55/55 B/s sample.
    linkStats.add(const LinkStats(
      timestampMs: 1000,
      totalBytes: 100,
      matchedBytes: 55,
      garbageBytes: 45,
      matchedPackets: 1,
    ));
    await tester.pump();
    linkStats.add(const LinkStats(
      timestampMs: 2000,
      totalBytes: 210,
      matchedBytes: 110,
      garbageBytes: 100,
      matchedPackets: 2,
    ));
    await tester.pump();

    const readout = '55 ours · 55 unknown B/s';
    expect(find.text(readout), findsOneWidget);

    // Entering edit mode remounts every tile (AbsorbPointer + drag handles
    // wrap the tile content); leaving it remounts them again.
    await tester.tap(find.text('Edit layout'));
    await tester.pump();
    expect(find.text(readout), findsOneWidget);

    await tester.tap(find.text('Done'));
    await tester.pump();
    expect(find.text(readout), findsOneWidget);

    await linkStats.close();
  });
}
