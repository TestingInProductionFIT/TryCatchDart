import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:serial/serial.dart';
import 'package:trycatch/core/format.dart';
import 'package:trycatch/core/packet_rate_tracker.dart';
import 'package:trycatch/state/telemetry_provider.dart';
import 'package:trycatch/theme/app_colors.dart';
import 'package:trycatch/ui/components/link_stats_button.dart';

/// Pumps the top-bar link-stats button with stubbed streams.
///
/// [status] defaults to disconnected: the button must report live data
/// regardless of connection state.
Future<void> _pumpButton(
  WidgetTester tester, {
  SerialWorkerStatus status = const SerialWorkerStatus(),
  Stream<LinkStats>? linkStats,
  Stream<TelemetryPacket>? packets,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        serialStatusProvider.overrideWith((ref) => Stream.value(status)),
        linkStatsStreamProvider.overrideWith(
          (ref) => linkStats ?? const Stream.empty(),
        ),
        telemetryStreamProvider.overrideWith(
          (ref) => packets ?? const Stream.empty(),
        ),
      ],
      child: const MaterialApp(
        home: Scaffold(body: Center(child: LinkStatsButton())),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 100));
}

TelemetryPacket _packet() =>
    TelemetryPacket(receivedAtMs: 0, rawData: Uint8List(0));

void main() {
  group('LinkStatsButton (connection-agnostic)', () {
    testWidgets('shows unknown B/s + no-data rate while disconnected',
        (tester) async {
      await _pumpButton(
        tester,
        linkStats: Stream.fromIterable([
          const LinkStats(timestampMs: 1000),
          const LinkStats(
            timestampMs: 2000,
            totalBytes: 700,
            matchedBytes: 550,
            garbageBytes: 150,
            matchedPackets: 10,
          ),
        ]),
      );

      expect(find.text('OFFLINE'), findsNothing);
      expect(find.text('no data'), findsOneWidget);
      expect(find.text('150 B/s'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('shows live pkt/s while flowing', (tester) async {
      final packets = StreamController<TelemetryPacket>();
      addTearDown(packets.close);
      await _pumpButton(tester, packets: packets.stream);

      for (var i = 0; i < 4; i++) {
        for (var j = 0; j < 5; j++) {
          packets.add(_packet());
        }
        await tester.pump(const Duration(milliseconds: 250));
      }
      expect(find.textContaining(RegExp(r'\d+\.\d pkt/s')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('linkRateLabel', () {
    test('no data before the first packet', () {
      expect(linkRateLabel(PacketRateTracker(), 0), 'no data');
    });

    test('live rate while flowing, age past the 2 s window', () {
      final rate = PacketRateTracker();
      rate.recordPacket(1000);
      rate.recordPacket(1000);
      rate.sample(1000);
      rate.recordPacket(1500);
      rate.recordPacket(1500);
      rate.recordPacket(1500);
      rate.sample(1500);
      // 3 packets in the last 500 ms → live.
      expect(linkRateLabel(rate, 1500), '6.0 pkt/s');
      // 4 s of silence → age of the last packet instead of a blank.
      expect(linkRateLabel(rate, 5500), '4.0 s ago');
    });
  });

  group('dead link signals red', () {
    testWidgets('silent link reads red no matter the congestion',
        (tester) async {
      // Quiet frequency (150 B/s is mere activity) but no packets at all:
      // the pill must signal the dead link, not the quiet channel.
      await _pumpButton(
        tester,
        linkStats: Stream.fromIterable([
          const LinkStats(timestampMs: 1000),
          const LinkStats(
            timestampMs: 2000,
            totalBytes: 700,
            matchedBytes: 550,
            garbageBytes: 150,
            matchedPackets: 10,
          ),
        ]),
      );

      expect(find.text('OFFLINE'), findsNothing);
      expect(find.text('150 B/s'), findsOneWidget);
      expect(find.text('no data'), findsOneWidget);

      final pills = tester.widgetList<Container>(
        find.byWidgetPredicate(
          (w) =>
              w is Container &&
              w.decoration is BoxDecoration &&
              (w.decoration as BoxDecoration).border is Border,
        ),
      );
      expect(pills, hasLength(1));
      final border =
          (pills.single.decoration as BoxDecoration).border as Border;
      expect(
        border.top.color,
        AppColors.destructive.withValues(alpha: 0.5),
      );
      expect(tester.takeException(), isNull);
    });
  });

  group('linkStateColor', () {
    test('neutral before any data ever arrived', () {
      expect(
        linkStateColor(
            unmatchedBps: 0, packetsLive: false, hasData: false),
        AppColors.mutedForeground,
      );
    });

    test('dead link is red no matter the congestion', () {
      for (final bps in [0.0, 150.0, 600.0]) {
        expect(
          linkStateColor(
              unmatchedBps: bps, packetsLive: false, hasData: true),
          AppColors.destructive,
          reason: 'unmatched $bps B/s',
        );
      }
    });

    test('live link follows the congestion verdict', () {
      expect(
        linkStateColor(unmatchedBps: 0, packetsLive: true, hasData: true),
        AppColors.success,
      );
      expect(
        linkStateColor(
            unmatchedBps: 150, packetsLive: true, hasData: true),
        AppColors.warning,
      );
      expect(
        linkStateColor(
            unmatchedBps: 600, packetsLive: true, hasData: true),
        AppColors.destructive,
      );
    });
  });

  group('formatPacketAge', () {
    test('formats ms / seconds / minutes', () {
      expect(formatPacketAge(const Duration(milliseconds: 850)),
          '850 ms ago');
      expect(
          formatPacketAge(const Duration(milliseconds: 3200)), '3.2 s ago');
      expect(formatPacketAge(const Duration(seconds: 125)), '2m 5s ago');
    });
  });
}
