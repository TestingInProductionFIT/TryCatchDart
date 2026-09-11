import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:serial/serial.dart';
import 'package:trycatch/core/dead_reckoning.dart';
import 'package:trycatch/core/ring_buffer.dart';
import 'package:trycatch/state/replay_controller.dart';
import 'package:trycatch/state/telemetry_store.dart';
import 'package:trycatch/state/tile_registry.dart';
import 'package:trycatch/ui/components/waiting_for_data.dart';
import 'package:trycatch/ui/tiles/events_tile.dart';

/// The events tile: a live "N s ago" milestone log, and the same log with
/// flight times ("at M:SS", tap to seek) during a replay.
void main() {
  test('events tile is registered', () {
    expect(TileRegistry.byId('events'), isNotNull);
    expect(TileRegistry.byId('events')?.title, 'Events');
  });

  group('EventsTile', () {
    Future<void> pumpTile(
      WidgetTester tester, {
      TelemetryStore Function()? store,
      ReplayController Function()? replay,
    }) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            if (store != null) telemetryStoreProvider.overrideWith(store),
            if (replay != null) replayProvider.overrideWith(replay),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: SizedBox(
                width: 300,
                height: 400,
                child: const EventsTile(),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
    }

    testWidgets('live rows show ticking ages', (tester) async {
      final eventAtMs = DateTime.now().millisecondsSinceEpoch - 12345;
      await pumpTile(tester, store: () => _LiveStore(eventAtMs));

      expect(find.text('Launch'), findsOneWidget);
      expect(find.text('ARMED → ASCENT'), findsOneWidget);
      expect(find.text('12 s ago'), findsOneWidget);
    });

    testWidgets('live waits for data', (tester) async {
      await pumpTile(tester, store: _EmptyStore.new);
      expect(find.byType(WaitingForData), findsOneWidget);
    });

    testWidgets('live hints when eventless', (tester) async {
      await pumpTile(tester, store: () => _LiveStore(0, idleOnly: true));
      expect(find.text('No events yet'), findsOneWidget);
    });

    testWidgets('replay rows show flight times and seek on tap', (
      tester,
    ) async {
      final stub = _StubReplay(
        ReplayState(
          filePath: 'flight.bin',
          positionMs: 2000,
          durationMs: 2000,
          frames: [
            TelemetryFrame(receivedAtMs: 0, fsmStateId: FsmState.armed.id),
            TelemetryFrame(receivedAtMs: 1000, fsmStateId: FsmState.ascent.id),
            TelemetryFrame(receivedAtMs: 2000, fsmStateId: FsmState.apogee.id),
          ],
        ),
      );
      await pumpTile(tester, store: _ReplayStore.new, replay: () => stub);

      expect(find.text('Launch'), findsOneWidget);
      expect(find.text('Apogee'), findsOneWidget);
      expect(find.text('at 0:01'), findsOneWidget);
      expect(find.text('at 0:02'), findsOneWidget);

      await tester.tap(find.text('Apogee'));
      await tester.pump();
      expect(stub.sought, 2000);
    });

    testWidgets('replay without transitions explains itself', (tester) async {
      final stub = _StubReplay(
        ReplayState(
          filePath: 'pad.bin',
          durationMs: 2000,
          frames: [
            TelemetryFrame(receivedAtMs: 0, fsmStateId: FsmState.idle.id),
            TelemetryFrame(receivedAtMs: 2000, fsmStateId: FsmState.armed.id),
          ],
        ),
      );
      await pumpTile(tester, store: _ReplayStore.new, replay: () => stub);

      expect(find.text('No events in this recording'), findsOneWidget);
    });
  });
}

/// Live store with an armed→ascent launch at [eventAtMs] (or an idle-only
/// history when [idleOnly]).
class _LiveStore extends TelemetryStore {
  final int eventAtMs;
  final bool idleOnly;

  _LiveStore(this.eventAtMs, {this.idleOnly = false});

  @override
  TelemetryState build() {
    final history = RingBuffer<TelemetryFrame>(10);
    if (idleOnly) {
      const frame = TelemetryFrame(
        receivedAtMs: 0,
        fsmStateId: 0, // idle
      );
      history.push(frame);
      return TelemetryState(
        history: history,
        deadReckoningHistory: RingBuffer<DrPosition>(10),
        latest: frame,
      );
    }
    final launch = TelemetryFrame(
      receivedAtMs: eventAtMs,
      fsmStateId: FsmState.ascent.id,
    );
    history.push(
      TelemetryFrame(
        receivedAtMs: eventAtMs - 1000,
        fsmStateId: FsmState.armed.id,
      ),
    );
    history.push(launch);
    return TelemetryState(
      history: history,
      deadReckoningHistory: RingBuffer<DrPosition>(10),
      latest: launch,
    );
  }
}

class _EmptyStore extends TelemetryStore {
  @override
  TelemetryState build() => TelemetryState(
    history: RingBuffer<TelemetryFrame>(10),
    deadReckoningHistory: RingBuffer<DrPosition>(10),
  );
}

/// Replaying store with an empty ring: the tile reads the replay frames.
class _ReplayStore extends TelemetryStore {
  @override
  TelemetryState build() => TelemetryState(
    history: RingBuffer<TelemetryFrame>(10),
    deadReckoningHistory: RingBuffer<DrPosition>(10),
    replaying: true,
  );
}

class _StubReplay extends ReplayController {
  final ReplayState initial;

  int? sought;

  _StubReplay(this.initial);

  @override
  ReplayState build() => initial;

  @override
  void seek(int positionMs) {
    sought = positionMs;
    state = state.copyWith(positionMs: positionMs);
  }

  @override
  void pause() {}
}
