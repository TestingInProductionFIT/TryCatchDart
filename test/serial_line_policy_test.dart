import 'package:flutter_test/flutter_test.dart';
import 'package:serial/serial.dart';

// Regression pin for the ARM LoRa hang: opening the port must never assert
// modem lines or enable flow control. The dongles are 3-wire MCU adapters;
// DTR/RTS assertions hold the MCU in reset (and RTS/CTS flow control stalls
// TX on floating CTS) until the adapter is physically re-enumerated, i.e.
// the "connect bricks the LoRa until unplug/replug" bug. These constants are
// applied atomically in RealSerialPort.connect(); any change here must be a
// deliberate, hardware-tested decision.
void main() {
  test('serial line policy leaves the LoRa MCU running', () {
    // 8N1 framing is unchanged.
    expect(SerialHardwareConfig.baudRate, 115200);
    expect(SerialHardwareConfig.dataBits, 8);
    expect(SerialHardwareConfig.parity, 0);
    expect(SerialHardwareConfig.stopBits, 1);
    // No flow control of any kind; modem lines off/ignored.
    expect(SerialHardwareConfig.flowControl, 0);
    expect(SerialHardwareConfig.rts, 0);
    expect(SerialHardwareConfig.cts, 0);
    expect(SerialHardwareConfig.dtr, 0);
    expect(SerialHardwareConfig.dsr, 0);
    expect(SerialHardwareConfig.xonXoff, 0);
  });
}
