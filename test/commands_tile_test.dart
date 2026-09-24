import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:dead_reckoning/dead_reckoning.dart' show DeadReckoningPosition;
import 'package:serial/serial.dart';
import 'package:trycatch/core/ring_buffer.dart';
import 'package:trycatch/state/replay_controller.dart';
import 'package:trycatch/state/telemetry_provider.dart';
import 'package:trycatch/state/telemetry_store.dart';
import 'package:trycatch/ui/tile_registry.dart';
import 'package:trycatch/ui/components/waiting_for_data.dart';
import 'package:trycatch/ui/tiles/commands_tile.dart';

/// The commands tile: a live "N s ago" uplink log, and the same log with
/// flight times ("at M:SS", tap to seek) during a replay.
void main() {
  test('commands tile is registered', () {
    expect(TileRegistry.byId('commands'), isNotNull);
    expect(TileRegistry.byId('commands')?.title, 'Commands');
  });

  group('CommandsTile', () {
    Future<void> pumpTile(
      WidgetTester tester, {
      TelemetryStore Function()? store,
      CommandLog Function()? log,
      ReplayController Function()? replay,
    }) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            if (store != null) telemetryStoreProvider.overrideWith(store),
            if (log != null) commandLogProvider.overrideWith(log),
            if (replay != null) replayProvider.overrideWith(replay),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: SizedBox(
                width: 300,
                height: 400,
                child: const CommandsTile(),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
    }

    testWidgets('live rows show ticking ages', (tester) async {
      final sentAtMs = DateTime.now().millisecondsSinceEpoch - 12345;
      await pumpTile(
        tester,
        store: _NonEmptyStore.new,
        log: () => _StubLog([
          SentCommand(
            tsUs: sentAtMs * 1000,
            bytes: [0x54, 0x43, 0x01, 0x00],
            source: CommandSource.controlPanel,
          ),
        ]),
      );

      expect(find.text('Arm'), findsOneWidget);
      expect(find.text('CONTROL PANEL • SENT'), findsOneWidget);
      expect(find.text('12 s ago'), findsOneWidget);
    });

    testWidgets('live flags failed attempts', (tester) async {
      await pumpTile(
        tester,
        store: _NonEmptyStore.new,
        log: () => _StubLog([
          SentCommand(
            tsUs: DateTime.now().microsecondsSinceEpoch,
            bytes: [0x54, 0x43, 0x02, 0x00],
            status: CommandStatus.failed,
            source: CommandSource.fsm,
          ),
        ]),
      );

      expect(find.text('Disarm'), findsOneWidget);
      expect(find.text('FSM • FAILED'), findsOneWidget);
    });

    testWidgets('live waits for data', (tester) async {
      await pumpTile(tester, store: _EmptyStore.new, log: _StubLog.empty);
      expect(find.byType(WaitingForData), findsOneWidget);
    });

    testWidgets('live hints when nothing was sent yet', (tester) async {
      await pumpTile(
          tester, store: _NonEmptyStore.new, log: _StubLog.empty);
      expect(find.text('No commands yet'), findsOneWidget);
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
          commands: const [
            SentCommand(
              tsUs: 1500000,
              bytes: [0x54, 0x43, 0x01, 0x00],
              source: CommandSource.controlPanel,
            ),
          ],
        ),
      );
      await pumpTile(
        tester,
        store: _ReplayStore.new,
        log: _StubLog.empty,
        replay: () => stub,
      );

      expect(find.text('Arm'), findsOneWidget);
      expect(find.text('at 0:01'), findsOneWidget);

      await tester.tap(find.text('Arm'));
      await tester.pump();
      expect(stub.sought, 1500);
    });

    testWidgets('replay without commands explains itself', (tester) async {
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
      await pumpTile(
        tester,
        store: _ReplayStore.new,
        log: _StubLog.empty,
        replay: () => stub,
      );

      expect(find.text('No commands in this recording'), findsOneWidget);
    });
  });
}

/// Store with one idle frame: non-empty history, so the tile shows the
/// command log (or its empty hint) instead of [WaitingForData].
class _NonEmptyStore extends TelemetryStore {
  @override
  TelemetryState build() {
    final history = RingBuffer<TelemetryFrame>(10);
    const frame = TelemetryFrame(
      receivedAtMs: 0,
      fsmStateId: 0, // idle
    );
    history.push(frame);
    return TelemetryState(
      history: history,
      deadReckoningHistory: RingBuffer<DeadReckoningPosition>(10),
      latest: frame,
    );
  }
}

class _EmptyStore extends TelemetryStore {
  @override
  TelemetryState build() => TelemetryState(
    history: RingBuffer<TelemetryFrame>(10),
    deadReckoningHistory: RingBuffer<DeadReckoningPosition>(10),
  );
}

/// Replaying store with an empty ring: the tile reads the replay commands.
class _ReplayStore extends TelemetryStore {
  @override
  TelemetryState build() => TelemetryState(
    history: RingBuffer<TelemetryFrame>(10),
    deadReckoningHistory: RingBuffer<DeadReckoningPosition>(10),
    replaying: true,
  );
}

/// Command log with a fixed content (no worker stream involved).
class _StubLog extends CommandLog {
  final List<SentCommand> initial;

  _StubLog(this.initial);

  _StubLog.empty() : initial = const [];

  @override
  List<SentCommand> build() => initial;
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
