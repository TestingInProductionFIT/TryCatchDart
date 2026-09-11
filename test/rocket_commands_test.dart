import 'package:flutter_test/flutter_test.dart';
import 'package:serial/serial.dart';

void main() {
  group('RocketCommand / RocketCommands', () {
    test('all commands have valid wire byte framing', () {
      for (final cmd in RocketCommands.all) {
        expect(cmd.bytes.length, 4);
        expect(cmd.bytes[0], rocketMagicT);
        expect(cmd.bytes[1], rocketMagicC);
        expect(cmd.bytes[0], 0x54);
        expect(cmd.bytes[1], 0x43);
      }
    });

    test('expected command bytes are defined', () {
      final arm = RocketCommands.all.firstWhere((c) => c.id == 'arm');
      expect(arm.bytes, [0x54, 0x43, 0x01, 0x00]);
      expect(arm.danger, isTrue);

      final disarm = RocketCommands.all.firstWhere((c) => c.id == 'disarm');
      expect(disarm.bytes, [0x54, 0x43, 0x02, 0x00]);
      expect(disarm.danger, isFalse);

      final chute = RocketCommands.all.firstWhere((c) => c.id == 'fire_parachute');
      expect(chute.bytes, [0x54, 0x43, 0x03, 0x00]);
      expect(chute.danger, isTrue);

      final beep = RocketCommands.all.firstWhere((c) => c.id == 'beep');
      expect(beep.bytes, [0x54, 0x43, 0x05, 0x00]);
      expect(beep.danger, isFalse);

      final reset = RocketCommands.all.firstWhere((c) => c.id == 'reset_fsm');
      expect(reset.bytes, [0x54, 0x43, 0x06, 0x00]);
      expect(reset.danger, isTrue);
    });
  });

  group('FsmStateCommands', () {
    test('bytesFor generates valid magic and command byte', () {
      for (final state in FsmState.values) {
        final bytes = FsmStateCommands.bytesFor(state);
        expect(bytes.length, 4);
        expect(bytes[0], 0x54);
        expect(bytes[1], 0x43);
        expect(bytes[2], 0x07);
        expect(bytes[3], state.id);
      }
    });
  });
}
