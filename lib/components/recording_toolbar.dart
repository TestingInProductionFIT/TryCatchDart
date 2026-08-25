import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:serial/serial.dart';
import 'package:trycatch/src/telemetry/telemetry_provider.dart';

/// A control widget for managing telemetry recording sessions.
///
/// Displays:
/// - Recording status indicator (ACTIVE / IDLE)
/// - Elapsed recording duration timer (HH:MM:SS)
/// - Start / Stop recording toggle button
/// - Clickable link/button to open the output directory in the OS file explorer
class RecordingToolbar extends ConsumerStatefulWidget {
  const RecordingToolbar({super.key});

  @override
  ConsumerState<RecordingToolbar> createState() => _RecordingToolbarState();
}

class _RecordingToolbarState extends ConsumerState<RecordingToolbar> {
  Timer? _durationTimer;
  DateTime? _recordingStartTime;
  Duration _elapsedDuration = Duration.zero;

  @override
  void dispose() {
    _durationTimer?.cancel();
    super.dispose();
  }

  void _onRecordingStateChanged(bool isRecording) {
    if (isRecording && _durationTimer == null) {
      _recordingStartTime = DateTime.now();
      _elapsedDuration = Duration.zero;
      _durationTimer = Timer.periodic(const Duration(seconds: 1), (_) {
        if (_recordingStartTime != null && mounted) {
          setState(() {
            _elapsedDuration = DateTime.now().difference(_recordingStartTime!);
          });
        }
      });
    } else if (!isRecording && _durationTimer != null) {
      _durationTimer?.cancel();
      _durationTimer = null;
      _recordingStartTime = null;
    }
  }

  String _formatDuration(Duration d) {
    final hours = d.inHours.toString().padLeft(2, '0');
    final minutes = (d.inMinutes % 60).toString().padLeft(2, '0');
    final seconds = (d.inSeconds % 60).toString().padLeft(2, '0');
    return '$hours:$minutes:$seconds';
  }

  @override
  Widget build(BuildContext context) {
    final status =
        ref.watch(serialStatusProvider).value ?? const SerialWorkerStatus();
    final notifier = ref.read(serialConfigProvider.notifier);

    // Sync timer with authoritative worker status
    _onRecordingStateChanged(status.isRecording);

    final folderPath =
        ref.watch(recordingsDirectoryProvider).value ??
        'Documents/TryCatch/recordings';

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Wrap(
        spacing: 16,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        alignment: WrapAlignment.spaceBetween,
        children: [
          // Left side: Status badge & Duration timer
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Recording Badge
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 6,
                ),
                decoration: BoxDecoration(
                  color: status.isRecording
                      ? Colors.red.shade700
                      : Colors.grey.shade700,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (status.isRecording) ...[
                      const Icon(
                        Icons.fiber_manual_record,
                        color: Colors.white,
                        size: 12,
                      ),
                      const SizedBox(width: 4),
                    ],
                    Text(
                      status.isRecording ? 'RECORDING' : 'REC STANDBY',
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                        fontSize: 11,
                      ),
                    ),
                  ],
                ),
              ),

              const SizedBox(width: 12),

              // Duration Timer
              if (status.isRecording)
                Text(
                  _formatDuration(_elapsedDuration),
                  style: const TextStyle(
                    fontFamily: 'Monospace',
                    fontWeight: FontWeight.bold,
                    fontSize: 14,
                    color: Colors.redAccent,
                  ),
                )
              else
                Text(
                  '00:00:00',
                  style: TextStyle(
                    fontFamily: 'Monospace',
                    color: Colors.grey.shade500,
                    fontSize: 14,
                  ),
                ),
            ],
          ),

          // Center/Right: Action Buttons & Folder Link
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Start / Stop Recording Button
              if (!status.isRecording)
                ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.red.shade700,
                    foregroundColor: Colors.white,
                  ),
                  icon: const Icon(Icons.fiber_manual_record, size: 16),
                  label: const Text('Start Recording'),
                  onPressed: () => notifier.startRecording(),
                )
              else
                ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.grey.shade800,
                    foregroundColor: Colors.white,
                  ),
                  icon: const Icon(Icons.stop, size: 16),
                  label: const Text('Stop Recording'),
                  onPressed: () => notifier.stopRecording(),
                ),

              const SizedBox(width: 12),

              // Open Folder Link Button
              Tooltip(
                message: folderPath,
                child: OutlinedButton.icon(
                  icon: const Icon(Icons.folder_open, size: 18),
                  label: const Text('Open Output Folder'),
                  onPressed: () => notifier.openRecordingsFolder(),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
