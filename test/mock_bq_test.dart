import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:serial/serial.dart';

void main() {
  group('MOCK-BQ dropout cycle', () {
    test('port name is distinct from MOCK', () {
      expect(MockBqSerialPort.portName, 'MOCK-BQ');
      expect(MockBqSerialPort.portName, isNot(MockSerialPort.portName));
    });

    test('emits ~10 s then drops ~5 s every ~15 s (@10 Hz)', () {
      // Ticks 0-99 emit, 100-149 drop, then repeats.
      for (var tick = 0; tick < 100; tick++) {
        expect(mockBqDropoutForTick(tick), isFalse, reason: 'tick $tick');
      }
      for (var tick = 100; tick < 150; tick++) {
        expect(mockBqDropoutForTick(tick), isTrue, reason: 'tick $tick');
      }
      // Cycle repeats.
      expect(mockBqDropoutForTick(150), isFalse);
      expect(mockBqDropoutForTick(250), isTrue);
      expect(mockBqDropoutForTick(300), isFalse);
    });

    test('cycle constants describe 10 s on / 5 s off', () {
      expect(mockBqPeriodTicks, 150);
      expect(mockBqOnTicks, 100);
      expect(mockBqOffTicks, 50);
    });

    test('connect/disconnect/sendBytes lifecycle', () async {
      final port = MockBqSerialPort();
      addTearDown(port.disconnect);
      expect(port.isConnected, isFalse);
      expect(port.connect(), isTrue);
      expect(port.isConnected, isTrue);
      port.disconnect();
      expect(port.isConnected, isFalse);
    });

    test('link goes silent during the dropout window', () {
      FakeAsync().run((async) {
        final port = MockBqSerialPort();
        final chunks = <List<int>>[];
        final sub = port.byteStream.listen(chunks.add);
        port.connect();
        async.elapse(const Duration(seconds: 10));
        async.flushMicrotasks();
        expect(chunks, isNotEmpty);

        chunks.clear();
        async.elapse(const Duration(seconds: 5));
        async.flushMicrotasks();
        expect(chunks, isEmpty);

        // Link recovers on the next cycle.
        async.elapse(const Duration(milliseconds: 300));
        async.flushMicrotasks();
        expect(chunks, isNotEmpty);

        port.disconnect();
        sub.cancel();
      });
    });

    // NOTE: SerialService.availablePorts is not covered here — it queries
    // native libserialport, whose DLL is absent under `flutter test`.
    // The worker test path covers the port list on-device.
    test('SerialService connects to MOCK-BQ as a mock', () {
      final service = SerialService();
      addTearDown(service.disconnect);
      expect(service.connect(MockBqSerialPort.portName), isTrue);
      expect(service.isConnected, isTrue);
      service.disconnect();
      expect(service.isConnected, isFalse);
    });
  });
}
