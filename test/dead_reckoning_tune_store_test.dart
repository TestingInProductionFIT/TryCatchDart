import 'dart:convert';

import 'package:dead_reckoning/dead_reckoning.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:serial/serial.dart' show TelemetryFrame;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:trycatch/core/ring_buffer.dart';
import 'package:trycatch/services/prefs_keys.dart';
import 'package:trycatch/state/dead_reckoning_tune_store.dart';
import 'package:trycatch/state/telemetry_store.dart';

class _StubStore extends TelemetryStore {
  DeadReckoningTune? appliedTune;

  @override
  TelemetryState build() => TelemetryState(
        history: RingBuffer<TelemetryFrame>(10),
        deadReckoningHistory: RingBuffer<DeadReckoningPosition>(10),
      );

  @override
  void setDeadReckoningTune(DeadReckoningTune tune) {
    appliedTune = tune;
  }
}

ProviderContainer _container() => ProviderContainer(
      overrides: [telemetryStoreProvider.overrideWith(_StubStore.new)],
    );

_StubStore _stubOf(ProviderContainer container) =>
    container.read(telemetryStoreProvider.notifier) as _StubStore;

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('starts at defaults with empty storage', () {
    final container = _container();
    addTearDown(container.dispose);
    expect(container.read(deadReckoningTuneProvider),
        DeadReckoningTune.defaults);
  });

  test('setTune applies live and persists JSON', () async {
    final container = _container();
    addTearDown(container.dispose);
    const tune = DeadReckoningTune(horizontalDrag: 0.05);

    await container.read(deadReckoningTuneProvider.notifier).setTune(tune);

    expect(container.read(deadReckoningTuneProvider), tune);
    expect(_stubOf(container).appliedTune, tune);
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(PrefsKeys.deadReckoningTune);
    expect(raw, isNotNull);
    expect(
      DeadReckoningTune.fromJson(
          jsonDecode(raw!) as Map<String, Object?>),
      tune,
    );
  });

  test('loads the persisted tune on start', () async {
    const tune = DeadReckoningTune(
      gravity: 9.81,
      groundToleranceM: 3,
      maxExtrapolationSeconds: 120,
    );
    SharedPreferences.setMockInitialValues({
      PrefsKeys.deadReckoningTune: jsonEncode(tune.toJson()),
    });
    final container = _container();
    addTearDown(container.dispose);

    // The load is async fire-and-forget off build(): trigger the build
    // first, then wait for the load to land.
    expect(container.read(deadReckoningTuneProvider),
        DeadReckoningTune.defaults);
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(container.read(deadReckoningTuneProvider), tune);
    expect(_stubOf(container).appliedTune, tune);
  });

  test('ignores a corrupt persisted tune', () async {
    SharedPreferences.setMockInitialValues({
      PrefsKeys.deadReckoningTune: 'definitely not a tune',
    });
    final container = _container();
    addTearDown(container.dispose);

    container.read(deadReckoningTuneProvider);
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(container.read(deadReckoningTuneProvider),
        DeadReckoningTune.defaults);
  });

  test('parsePersisted accepts compact, JSON and rejects garbage', () {
    const tune = DeadReckoningTune(horizontalDrag: 0.03);
    expect(
      DeadReckoningTuneController.parsePersisted(tune.toCompactString()),
      tune,
    );
    expect(
      DeadReckoningTuneController.parsePersisted(jsonEncode(tune.toJson())),
      tune,
    );
    expect(DeadReckoningTuneController.parsePersisted('nonsense'), isNull);
  });

  test('resetToDefaults restores factory defaults', () async {
    final container = _container();
    addTearDown(container.dispose);
    await container
        .read(deadReckoningTuneProvider.notifier)
        .setTune(const DeadReckoningTune(horizontalDrag: 0.05));
    await container.read(deadReckoningTuneProvider.notifier).resetToDefaults();
    expect(container.read(deadReckoningTuneProvider),
        DeadReckoningTune.defaults);
  });
}
