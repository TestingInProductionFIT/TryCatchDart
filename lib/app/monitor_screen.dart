import 'package:flutter/material.dart';

import '../components/channel_health_monitor.dart';

/// Developer screen showing live channel health (foreign traffic on our
/// frequency). Live radio only — unaffected by replay.
class MonitorScreen extends StatelessWidget {
  const MonitorScreen({super.key});

  @override
  Widget build(BuildContext context) {
    // NOTE: non-const so dark-mode flips repaint (AppColors is dynamic).
    return ChannelHealthMonitor();
  }
}
