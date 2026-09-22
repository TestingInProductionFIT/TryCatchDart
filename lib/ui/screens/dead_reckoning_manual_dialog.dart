import 'package:dead_reckoning/dead_reckoning.dart';
import 'package:flutter/material.dart';

import '../../theme/app_colors.dart';

// ── Manual tune dialog ───────────────────────────────────────────────────────
// Number grid with explanations, grouped by topic. Opened from the
// overview so the home state stays short.

class ManualTuneDialog extends StatefulWidget {
  final DeadReckoningTune initial;

  const ManualTuneDialog({super.key, required this.initial});

  @override
  State<ManualTuneDialog> createState() => _ManualTuneDialogState();
}

/// Field keys for [_controllers]; stringly-typed on purpose to keep the
/// `ValueKey('tune-$key')` test contract stable.
class _ManualKeys {
  static const scale = 'scale';
  static const drag = 'drag';
  static const smoothing = 'smoothing';
  static const tolerance = 'tolerance';
  static const horizClamp = 'horizClamp';
  static const vertClamp = 'vertClamp';
  static const horizon = 'horizon';
}

class _ManualTuneDialogState extends State<ManualTuneDialog> {
  final _controllers = <String, TextEditingController>{};
  late bool _tracking;
  String? _error;

  static String _num(double v) => v
      .toStringAsFixed(3)
      .replaceAll(RegExp(r'0+$'), '')
      .replaceAll(RegExp(r'\.$'), '.0');

  @override
  void initState() {
    super.initState();
    final tune = widget.initial;
    _tracking = tune.accelerationTracking;
    for (final field in _manualFields(tune)) {
      _controllers[field.key] = TextEditingController(text: field.initial);
    }
  }

  @override
  void dispose() {
    for (final controller in _controllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  static double? _parse(String text) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return null;
    return double.tryParse(trimmed.replaceAll(',', '.'));
  }

  void _save() {
    final values = <String, double?>{
      for (final entry in _controllers.entries)
        entry.key: _parse(entry.value.text),
    };
    final error = _ManualFormData.validate(values);
    if (error != null) {
      setState(() => _error = error);
      return;
    }
    Navigator.of(context).pop(DeadReckoningTune(
      gravity: widget.initial.gravity,
      horizontalDrag: values[_ManualKeys.drag]!,
      velocityFilterAlpha: values[_ManualKeys.smoothing]!,
      velocityScale: values[_ManualKeys.scale]!,
      accelerationTracking: _tracking,
      maxHorizontalSpeed: values[_ManualKeys.horizClamp],
      maxVerticalSpeed: values[_ManualKeys.vertClamp],
      groundToleranceM: values[_ManualKeys.tolerance]!,
      maxExtrapolationSeconds: values[_ManualKeys.horizon],
    ));
  }

  @override
  Widget build(BuildContext context) {
    final rows = <Widget>[
      Text(
        'Gravity is ${widget.initial.gravity.toStringAsFixed(2)} m/s² — fixed physics, not tuned. '
        'Vertical speed calibrates itself from each flight.',
        style: TextStyle(fontSize: 12, color: AppColors.mutedForeground),
      ),
    ];
    String? lastSection;
    for (final field in _manualFields(widget.initial)) {
      if (field.section != lastSection) {
        lastSection = field.section;
        rows.add(
          Padding(
            padding: const EdgeInsets.only(top: 8, bottom: 2),
            child: Text(
              field.section,
              style:
                  const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
            ),
          ),
        );
      }
      if (field.key == _ManualKeys.drag) {
        rows.add(Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: _TrackingRow(
            value: _tracking,
            onChanged: (value) => setState(() => _tracking = value),
          ),
        ));
      }
      rows.add(Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: _TuneNumberRow(
          fieldKey: field.key,
          label: field.label,
          explanation: field.explanation,
          hint: field.hint,
          controller: _controllers[field.key]!,
        ),
      ));
    }
    if (_error != null) {
      rows.add(Text(
        _error!,
        style: TextStyle(fontSize: 12.5, color: AppColors.destructive),
      ));
    }
    return AlertDialog(
      title: const Text('Manual tune'),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: rows,
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () =>
              Navigator.of(context).pop(DeadReckoningTune.defaults),
          child: const Text('Reset'),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _save,
          child: const Text('Use this tune'),
        ),
      ],
    );
  }
}

/// Validates parsed number values; returns the error string or `null`.
class _ManualFormData {
  static String? validate(Map<String, double?> values) {
    final scale = values[_ManualKeys.scale];
    final drag = values[_ManualKeys.drag];
    final smoothing = values[_ManualKeys.smoothing];
    final tolerance = values[_ManualKeys.tolerance];
    if (scale == null || scale < 0.2 || scale > 3) {
      return 'Velocity scale must be 0.2–3.';
    }
    if (drag == null || drag < 0 || drag > 1) {
      return 'Horizontal drag must be 0–1.';
    }
    if (smoothing == null || smoothing < 0.05 || smoothing > 1) {
      return 'Velocity smoothing must be 0.05–1.';
    }
    if (tolerance == null || tolerance < 0 || tolerance > 20) {
      return 'Ground tolerance must be 0–20 m.';
    }
    for (final key in const [_ManualKeys.horizClamp, _ManualKeys.vertClamp]) {
      final v = values[key];
      if (v != null && (v < 1 || v > 1000)) {
        return 'Speed caps must be 1–1000 m/s or empty.';
      }
    }
    final horizon = values[_ManualKeys.horizon];
    if (horizon != null && (horizon < 1 || horizon > 3600)) {
      return 'Horizon must be 1–3600 s or empty.';
    }
    return null;
  }
}

/// Shared label + explanation column for dialog rows.
class _FieldLabel extends StatelessWidget {
  final String label;
  final String explanation;

  const _FieldLabel({required this.label, required this.explanation});

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label,
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
          ),
          Text(
            explanation,
            style: TextStyle(
                fontSize: 11.5, color: AppColors.mutedForeground),
          ),
        ],
      ),
    );
  }
}

/// Acceleration-trend switch row.
class _TrackingRow extends StatelessWidget {
  final bool value;
  final ValueChanged<bool> onChanged;

  const _TrackingRow({required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _FieldLabel(
          label: 'Follow acceleration trend',
          explanation: 'Bend projections along recent motion. Off holds '
              'velocity constant.',
        ),
        const SizedBox(width: 12),
        Switch(value: value, onChanged: onChanged),
      ],
    );
  }
}

/// Number-field row (keeps the `ValueKey('tune-$key')` test contract).
class _TuneNumberRow extends StatelessWidget {
  final String fieldKey;
  final String label;
  final String explanation;
  final String hint;
  final TextEditingController controller;

  const _TuneNumberRow({
    required this.fieldKey,
    required this.label,
    required this.explanation,
    required this.hint,
    required this.controller,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _FieldLabel(label: label, explanation: explanation),
        const SizedBox(width: 12),
        SizedBox(
          width: 110,
          child: TextField(
            key: ValueKey('tune-$fieldKey'),
            controller: controller,
            keyboardType:
                const TextInputType.numberWithOptions(decimal: true),
            decoration: InputDecoration(
              hintText: hint,
              border: const OutlineInputBorder(),
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            ),
          ),
        ),
      ],
    );
  }
}

/// Manual field definitions (key, section, label, explanation, hint).
List<_TuneField> _manualFields(DeadReckoningTune tune) => [
      _TuneField(
        key: _ManualKeys.scale,
        section: 'Sensor fit',
        label: 'Velocity scale',
        explanation:
            'Compensates per-rocket sensor error. 1.0 trusts the sensor; higher stretches its speed readings.',
        hint: 'e.g. 1.10',
        initial: _ManualTuneDialogState._num(tune.velocityScale),
      ),
      _TuneField(
        key: _ManualKeys.smoothing,
        section: 'Sensor fit',
        label: 'Velocity smoothing',
        explanation:
            'Low-pass on fresh velocity, 0–1. 1.0 takes samples raw; lower ignores single-sample spikes.',
        hint: 'e.g. 0.85',
        initial: _ManualTuneDialogState._num(tune.velocityFilterAlpha),
      ),
      _TuneField(
        key: _ManualKeys.drag,
        section: 'Motion',
        label: 'Horizontal drag',
        explanation:
            'Slows the guess during long outages. 0 holds speed constant (widest search area).',
        hint: 'e.g. 0.02',
        initial: _ManualTuneDialogState._num(tune.horizontalDrag),
      ),
      _TuneField(
        key: _ManualKeys.tolerance,
        section: 'Limits',
        label: 'Ground tolerance',
        explanation:
            'Metres below the lowest fix before the estimate counts as landed.',
        hint: 'e.g. 2.0',
        initial: _ManualTuneDialogState._num(tune.groundToleranceM),
      ),
      _TuneField(
        key: _ManualKeys.horizClamp,
        section: 'Limits',
        label: 'Max horizontal speed',
        explanation:
            'Caps adopted horizontal speed in m/s. Empty means no cap.',
        hint: 'empty = off',
        initial: tune.maxHorizontalSpeed?.toStringAsFixed(0) ?? '',
      ),
      _TuneField(
        key: _ManualKeys.vertClamp,
        section: 'Limits',
        label: 'Max vertical speed',
        explanation:
            'Caps adopted vertical speed in m/s. Empty means no cap.',
        hint: 'empty = off',
        initial: tune.maxVerticalSpeed?.toStringAsFixed(0) ?? '',
      ),
      _TuneField(
        key: _ManualKeys.horizon,
        section: 'Limits',
        label: 'Extrapolation horizon',
        explanation:
            'Seconds after the last fix before the estimate freezes as expired. Empty means unbounded.',
        hint: 'empty = off',
        initial: tune.maxExtrapolationSeconds?.toStringAsFixed(0) ?? '',
      ),
    ];

// ── Manual tune fields ───────────────────────────────────────────────────────
// One definition drives both the section headings and the number rows in
// the manual dialog.

class _TuneField {
  final String key;
  final String section;
  final String label;
  final String explanation;
  final String hint;
  final String initial;

  _TuneField({
    required this.key,
    required this.section,
    required this.label,
    required this.explanation,
    required this.hint,
    required this.initial,
  });
}

