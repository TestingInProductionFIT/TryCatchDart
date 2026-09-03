import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:serial/serial.dart';

import '../theme/app_colors.dart';
import '/src/telemetry/telemetry_provider.dart';

/// Recording control for the REC cell of the top bar: a Record button when
/// idle, or the elapsed time with a stop action while recording. Fixed width.
class RecordingControls extends ConsumerStatefulWidget {
  static const double width = 132;

  const RecordingControls({super.key});

  @override
  ConsumerState<RecordingControls> createState() => _RecordingControlsState();
}

class _RecordingControlsState extends ConsumerState<RecordingControls> {
  DateTime? _startedAt;
  Timer? _ticker;

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  void _syncWithStatus(bool isRecording) {
    if (isRecording && _startedAt == null) {
      _startedAt = DateTime.now();
      _ticker = Timer.periodic(const Duration(milliseconds: 500), (_) {
        if (mounted) setState(() {});
      });
    } else if (!isRecording && _startedAt != null) {
      _startedAt = null;
      _ticker?.cancel();
      _ticker = null;
    }
  }

  String _elapsed() {
    final started = _startedAt;
    if (started == null) return '0:00';
    final d = DateTime.now().difference(started);
    return '${d.inMinutes}:${(d.inSeconds % 60).toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final status =
        ref.watch(serialStatusProvider).value ?? const SerialWorkerStatus();
    _syncWithStatus(status.isRecording);

    Widget child;
    if (status.isRecording) {
      child = FilledButton.icon(
        onPressed: ref.read(serialConfigProvider.notifier).stopRecording,
        style: FilledButton.styleFrom(
          backgroundColor: AppColors.destructive,
          foregroundColor: Colors.white,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          minimumSize: const Size(0, 32),
          textStyle: const TextStyle(
              fontSize: 12.5, fontWeight: FontWeight.w600),
        ),
        icon: const Icon(Icons.stop_rounded, size: 15),
        label: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const _RecordingDot(),
            const SizedBox(width: 6),
            Text(
              _elapsed(),
              style: AppText.mono.copyWith(
                fontSize: 12.5,
                fontWeight: FontWeight.w700,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ],
        ),
      );
    } else {
      child = OutlinedButton.icon(
        onPressed: ref.read(serialConfigProvider.notifier).startRecording,
        style: OutlinedButton.styleFrom(
          foregroundColor: AppColors.destructive,
          side: const BorderSide(color: AppColors.destructive),
          padding: const EdgeInsets.symmetric(horizontal: 12),
          minimumSize: const Size(0, 32),
          textStyle: const TextStyle(
              fontSize: 12.5, fontWeight: FontWeight.w600),
        ),
        icon: const Icon(Icons.radio_button_checked, size: 14),
        label: const Text('Record'),
      );
    }

    return SizedBox(
      width: RecordingControls.width,
      child: Align(alignment: Alignment.centerRight, child: child),
    );
  }
}

class _RecordingDot extends StatefulWidget {
  const _RecordingDot();

  @override
  State<_RecordingDot> createState() => _RecordingDotState();
}

class _RecordingDotState extends State<_RecordingDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 700),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: Tween(begin: 0.25, end: 1.0).animate(_c),
      child: Container(
        width: 8,
        height: 8,
        decoration: const BoxDecoration(
          shape: BoxShape.circle,
          color: Colors.white,
        ),
      ),
    );
  }
}
