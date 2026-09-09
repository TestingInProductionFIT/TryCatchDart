import 'package:flutter/material.dart';

import '../components/raw_byte_monitor.dart';

/// Developer screen showing the raw parsed packet feed.
class MonitorScreen extends StatelessWidget {
  const MonitorScreen({super.key});

  @override
  Widget build(BuildContext context) {
    // NOTE: non-const so dark-mode flips repaint (AppColors is dynamic).
    return RawByteMonitor();
  }
}
