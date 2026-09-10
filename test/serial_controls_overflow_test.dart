import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:serial/serial.dart';
import 'package:trycatch/state/telemetry_provider.dart';
import 'package:trycatch/ui/components/serial_controls.dart';

/// Pumps [SerialControls] in a topbar-like strip and fails on any layout
/// overflow (RenderFlex overflows surface via [WidgetTester.takeException]).
Future<void> _pumpControls(
  WidgetTester tester, {
  List<String> ports = const [],
  SerialWorkerStatus status = const SerialWorkerStatus(),
  String? selectedPort,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        availablePortsProvider
            .overrideWith((ref) => Stream.value(ports)),
        serialStatusProvider
            .overrideWith((ref) => Stream.value(status)),
        if (selectedPort != null)
          serialConfigProvider.overrideWith(_SeededConfig.seed(selectedPort)),
      ],
      child: const MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 400,
              height: 52,
              child: Center(child: SerialControls()),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

class _SeededConfig extends SerialConfigNotifier {
  final SerialConfig _seed;

  _SeededConfig(this._seed);

  @override
  SerialConfig build() => _seed;

  static _SeededConfig Function() seed(String port) =>
      () => _SeededConfig(SerialConfig(selectedPort: port));
}

void main() {
  group('SerialControls overflow', () {
    testWidgets('no ports', (tester) async {
      await _pumpControls(tester);
      expect(tester.takeException(), isNull);
    });

    testWidgets('short port selected', (tester) async {
      await _pumpControls(
        tester,
        ports: const ['MOCK'],
        selectedPort: 'MOCK',
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('long port name selected', (tester) async {
      await _pumpControls(
        tester,
        ports: const ['COM3 - USB-SERIAL CH340 (COM3)'],
        selectedPort: 'COM3 - USB-SERIAL CH340 (COM3)',
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('connected', (tester) async {
      await _pumpControls(
        tester,
        ports: const ['MOCK'],
        status: const SerialWorkerStatus(
          isConnected: true,
          connectedPort: 'MOCK',
        ),
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('long connected port name', (tester) async {
      await _pumpControls(
        tester,
        ports: const ['/dev/ttyUSB0 - Silicon Labs CP210x'],
        status: const SerialWorkerStatus(
          isConnected: true,
          connectedPort: '/dev/ttyUSB0 - Silicon Labs CP210x',
        ),
      );
      expect(tester.takeException(), isNull);
    });
  });
}
