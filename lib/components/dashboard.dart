import 'package:flutter/material.dart';
import 'package:trycatch/components/raw_byte_monitor.dart';
import 'package:trycatch/components/recording_toolbar.dart';
import 'package:trycatch/components/serial_toolbar.dart';
import 'package:trycatch/components/telemetry_metrics_toolbar.dart';

class DashboardView extends StatelessWidget {
  const DashboardView({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('{TryCatch}')),
      body: const Padding(
        padding: EdgeInsets.all(12.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SerialToolbar(),
            SizedBox(height: 12),
            TelemetryMetricsToolbar(),
            SizedBox(height: 12),
            RecordingToolbar(),
            SizedBox(height: 16),
            RawByteMonitor(),
          ],
        ),
      ),
    );
  }
}
