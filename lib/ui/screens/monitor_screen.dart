import 'package:flutter/material.dart';

import '../tiles/channel_health_tile.dart';

/// Channel-health screen: ours vs unknown on our frequency.
/// Check this screen reads clear before launch. Live radio only —
/// unaffected by replay.
class MonitorScreen extends StatelessWidget {
  const MonitorScreen({super.key});

  @override
  Widget build(BuildContext context) {
    // NOTE: non-const so dark-mode flips repaint (AppColors is dynamic).
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(child: ChannelHealthMonitor()),
      ],
    );
  }
}
