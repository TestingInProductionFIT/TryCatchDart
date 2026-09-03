import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../src/telemetry/telemetry_provider.dart';
import '../../theme/app_colors.dart';

/// One data-defined command to the rocket.
///
/// Everything about a command — label, icon, exact wire bytes — lives here;
/// the widget renders and sends whatever is in this catalog. To add a
/// command, append one entry.
class RocketCommand {
  final String id;
  final String label;
  final String description;
  final IconData icon;
  final List<int> bytes;

  /// Destructive commands get red accents and a stronger confirmation style.
  final bool danger;

  const RocketCommand({
    required this.id,
    required this.label,
    required this.description,
    required this.icon,
    required this.bytes,
    this.danger = false,
  });
}

/// Command catalog.
///
/// Byte format (made up, must match the flight software): `0x54 0x43` magic
/// ('TC') + command byte + argument byte (0x00 for now).
abstract final class RocketCommands {
  static const magicT = 0x54;
  static const magicC = 0x43;

  static const List<RocketCommand> all = [
    RocketCommand(
      id: 'arm',
      label: 'Arm',
      description: 'Enable igniter and deployment circuits',
      icon: Icons.gpp_good_outlined,
      bytes: [magicT, magicC, 0x01, 0x00],
      danger: true,
    ),
    RocketCommand(
      id: 'disarm',
      label: 'Disarm',
      description: 'Disable all pyro and igniter circuits',
      icon: Icons.gpp_bad_outlined,
      bytes: [magicT, magicC, 0x02, 0x00],
    ),
    RocketCommand(
      id: 'fire_drogue',
      label: 'Fire drogue',
      description: 'Manual drogue parachute deployment',
      icon: Icons.paragliding,
      bytes: [magicT, magicC, 0x03, 0x00],
      danger: true,
    ),
    RocketCommand(
      id: 'fire_main',
      label: 'Fire main',
      description: 'Manual main parachute deployment',
      icon: Icons.umbrella_outlined,
      bytes: [magicT, magicC, 0x04, 0x00],
      danger: true,
    ),
    RocketCommand(
      id: 'beep',
      label: 'Beep',
      description: 'Play the locator beep on the rocket',
      icon: Icons.campaign_outlined,
      bytes: [magicT, magicC, 0x05, 0x00],
    ),
    RocketCommand(
      id: 'reset_fsm',
      label: 'Reset FSM',
      description: 'Force the flight computer back to Idle',
      icon: Icons.restart_alt,
      bytes: [magicT, magicC, 0x06, 0x00],
      danger: true,
    ),
  ];
}

/// Two-click command panel: every tile requires a second confirming click
/// within 3 seconds before the bytes go out on the wire.
class ControlPanelWidget extends ConsumerStatefulWidget {
  const ControlPanelWidget({super.key});

  @override
  ConsumerState<ControlPanelWidget> createState() => _ControlPanelWidgetState();
}

class _ControlPanelWidgetState extends ConsumerState<ControlPanelWidget> {
  static const _confirmTimeout = Duration(seconds: 3);

  String? _armedCommandId;
  String? _sentCommandId;
  Timer? _timer;

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _onTileTap(RocketCommand command) {
    final notifier = ref.read(serialConfigProvider.notifier);
    final connected =
        ref.read(serialStatusProvider).value?.isConnected ?? false;
    if (!connected) return;

    if (_armedCommandId != command.id) {
      _timer?.cancel();
      setState(() {
        _armedCommandId = command.id;
        _sentCommandId = null;
      });
      _timer = Timer(_confirmTimeout, () {
        if (mounted) setState(() => _armedCommandId = null);
      });
      return;
    }

    _timer?.cancel();
    final ok = notifier.sendBytes(command.bytes);
    setState(() {
      _armedCommandId = null;
      _sentCommandId = ok ? command.id : null;
    });
    if (ok) {
      Timer(const Duration(seconds: 1), () {
        if (mounted && _sentCommandId == command.id) {
          setState(() => _sentCommandId = null);
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final connected =
        ref.watch(serialStatusProvider).value?.isConnected ?? false;

    // Buttons fill the tile: a 2-column grid (3 when wide) whose row height
    // is derived from the available height, so the buttons stretch to fill
    // the tile instead of sitting in a fixed 44px strip. Falls back to
    // scrolling at the 36px minimum when the tile is too short.
    return LayoutBuilder(builder: (context, constraints) {
      final columns = constraints.maxWidth > 460 ? 3 : 2;
      final rows = (RocketCommands.all.length / columns).ceil();
      final bounded = constraints.maxHeight.isFinite;
      final fillExtent =
          (constraints.maxHeight - 8 * (rows - 1)) / rows;
      final extent = bounded ? math.max(36.0, fillExtent) : 44.0;

      final grid = GridView(
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        padding: EdgeInsets.zero,
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: columns,
          mainAxisExtent: extent,
          crossAxisSpacing: 8,
          mainAxisSpacing: 8,
        ),
        children: [
          for (final command in RocketCommands.all)
            _CommandTile(
              command: command,
              state: _sentCommandId == command.id
                  ? _TileState.sent
                  : _armedCommandId == command.id
                      ? _TileState.confirm
                      : _TileState.idle,
              enabled: connected,
              onTap: () => _onTileTap(command),
            ),
        ],
      );

      if (bounded && fillExtent >= 36.0) return grid;
      return SingleChildScrollView(child: grid);
    });
  }
}

enum _TileState { idle, confirm, sent }

class _CommandTile extends StatelessWidget {
  final RocketCommand command;
  final _TileState state;
  final bool enabled;
  final VoidCallback onTap;

  const _CommandTile({
    required this.command,
    required this.state,
    required this.enabled,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final accent = command.danger ? AppColors.destructive : AppColors.primary;

    final Color background;
    final Color foreground;
    final Color border;
    final String label;
    final IconData icon;
    switch (state) {
      case _TileState.idle:
        background = AppColors.card;
        foreground = enabled ? AppColors.foreground : AppColors.strongBorder;
        border = AppColors.border;
        label = command.label;
        icon = command.icon;
      case _TileState.confirm:
        background = accent;
        foreground = Colors.white;
        border = accent;
        label = 'Tap again to confirm';
        icon = Icons.priority_high;
      case _TileState.sent:
        background = AppColors.success;
        foreground = Colors.white;
        border = AppColors.success;
        label = 'Sent';
        icon = Icons.check;
    }

    return Tooltip(
      message: enabled ? command.description : 'Connect first',
      waitDuration: const Duration(milliseconds: 500),
      child: Material(
        color: background,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppDimens.radiusSmall),
          side: BorderSide(
              color: state == _TileState.idle ? border : Colors.transparent,
              width: 1),
        ),
        child: InkWell(
          onTap: enabled ? onTap : null,
          borderRadius: BorderRadius.circular(AppDimens.radiusSmall),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              children: [
                Icon(
                  icon,
                  size: 17,
                  color: state == _TileState.idle
                      ? (enabled ? accent : AppColors.strongBorder)
                      : foreground,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    label,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                      color: foreground,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
