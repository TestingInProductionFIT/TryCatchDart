import 'telemetry_frame.dart';

/// Wire-byte command definitions for communicating with the rocket.
///
/// All uplink frames share the same framing:
///   `0x54 0x43` magic ('TC') + 1-byte command + 1-byte argument.
/// The command and argument values must match the flight software exactly.

// ── Magic header ─────────────────────────────────────────────────────────────

/// Magic byte 'T' (0x54) — first byte of every uplink frame.
const int rocketMagicT = 0x54;

/// Magic byte 'C' (0x43) — second byte of every uplink frame.
const int rocketMagicC = 0x43;

// ── Control-panel commands ───────────────────────────────────────────────────

/// One data-defined command to the rocket.
class RocketCommand {
  final String id;
  final String label;
  final String description;
  final List<int> bytes;

  /// Destructive commands get red accents and a stronger confirmation style.
  final bool danger;

  const RocketCommand({
    required this.id,
    required this.label,
    required this.description,
    required this.bytes,
    this.danger = false,
  });
}

/// Command catalog for uplink control.
abstract final class RocketCommands {
  static const magicT = rocketMagicT;
  static const magicC = rocketMagicC;

  static const List<RocketCommand> all = [
    RocketCommand(
      id: 'arm',
      label: 'Arm',
      description: 'Enable igniter and deployment circuits',
      bytes: [rocketMagicT, rocketMagicC, 0x01, 0x00],
      danger: true,
    ),
    RocketCommand(
      id: 'disarm',
      label: 'Disarm',
      description: 'Disable all pyro and igniter circuits',
      bytes: [rocketMagicT, rocketMagicC, 0x02, 0x00],
    ),
    RocketCommand(
      id: 'fire_parachute',
      label: 'Fire chute',
      description: 'Manual parachute deployment',
      bytes: [rocketMagicT, rocketMagicC, 0x03, 0x00],
      danger: true,
    ),
    RocketCommand(
      id: 'beep',
      label: 'Beep',
      description: 'Play the locator beep on the rocket',
      bytes: [rocketMagicT, rocketMagicC, 0x05, 0x00],
    ),
    RocketCommand(
      id: 'reset_fsm',
      label: 'Reset FSM',
      description: 'Force the flight computer back to Idle',
      bytes: [rocketMagicT, rocketMagicC, 0x06, 0x00],
      danger: true,
    ),
  ];
}

// ── FSM state commands ───────────────────────────────────────────────────────

/// Wire bytes for requesting an FSM state change from the rocket.
///
/// Frame format: magic + `0x07` (set-FSM-state command) + [FsmState.id].
/// The command byte `0x07` must match the flight software.
abstract final class FsmStateCommands {
  static const magicT = rocketMagicT;
  static const magicC = rocketMagicC;

  /// Command byte for the "set FSM state" uplink.
  static const int setStateCmd = 0x07;

  static List<int> bytesFor(FsmState state) =>
      [rocketMagicT, rocketMagicC, setStateCmd, state.id];
}
