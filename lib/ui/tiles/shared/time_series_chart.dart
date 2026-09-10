import 'dart:async';
import 'dart:math' as math;

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:serial/serial.dart';

import '../../../state/replay_controller.dart';
import '../../../state/telemetry_store.dart';
import '../../../theme/app_colors.dart';
import '../../components/waiting_for_data.dart';

/// One plotted series of a time-series chart.
class SeriesSpec {
  final String label;
  final Color color;
  final double Function(TelemetryFrame frame) value;
  final bool dashed;

  const SeriesSpec({
    required this.label,
    required this.color,
    required this.value,
    this.dashed = false,
  });
}

/// Configuration for [TimeSeriesChart] — every dashboard line chart (altitude,
/// velocity, acceleration, battery, hall) is a thin instantiation of this
/// tile so they all behave identically.
class TimeSeriesConfig {
  /// Unit shown in the legend.
  final String unit;

  final List<SeriesSpec> series;

  /// Rolling time window displayed (default: last minute).
  final Duration window;

  /// Fixed vertical axis; `null` → auto-scaled and snapped to round values.
  final double? yMin;
  final double? yMax;

  /// Whether to render the series legend (off when the host tile shows its
  /// own header, e.g. the hall sensor readout).
  final bool showLegend;

  /// Whether to render y-axis tick labels.
  final bool showLeftAxis;

  const TimeSeriesConfig({
    required this.unit,
    required this.series,
    this.window = const Duration(minutes: 1),
    this.yMin,
    this.yMax,
    this.showLegend = true,
    this.showLeftAxis = true,
  });
}

/// Shared touch tooltip for every dashboard line chart (time-series +
/// channel health).
///
/// One card-styled box in the app palette (card background, hairline border,
/// mono type) instead of fl_chart's default dark box, which is unreadable
/// against the themes. Content is a muted time header plus one short
/// single-line row per touched series in its own color, so values never
/// wrap; [fitInsideHorizontally]/[fitInsideVertically] keep the box
/// on-screen near the edges.
///
/// [entries] must align 1:1 with the chart's `lineBarsData` (including
/// dimmed replay duplicates) — the touched bar's index picks its row.
LineTouchData chartTouchData({
  required List<(String label, Color color)> entries,
  required String unit,
  required String Function(double x) formatX,
  required String Function(double y) formatY,
}) {
  final suffix = unit.isEmpty ? '' : ' $unit';
  return LineTouchData(
    handleBuiltInTouches: true,
    touchSpotThreshold: 12,
    getTouchedSpotIndicator: (bar, indexes) => [
      for (final _ in indexes)
        TouchedSpotIndicatorData(
          FlLine(color: AppColors.strongBorder, strokeWidth: 1),
          FlDotData(
            show: true,
            getDotPainter: (spot, percent, touchedBar, index) =>
                FlDotCirclePainter(
              radius: 3.5,
              color: touchedBar.color ?? AppColors.foreground,
              strokeWidth: 0,
            ),
          ),
        ),
    ],
    touchTooltipData: LineTouchTooltipData(
      getTooltipColor: (_) => AppColors.card,
      tooltipBorder: BorderSide(color: AppColors.strongBorder),
      tooltipBorderRadius:
          BorderRadius.circular(AppDimens.radiusSmall),
      tooltipPadding:
          const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      tooltipMargin: 16,
      fitInsideHorizontally: true,
      fitInsideVertically: true,
      maxContentWidth: 240,
      getTooltipItems: (spots) {
        // Must stay 1:1 with [spots] — fl_chart throws when the lengths
        // differ. The time header is folded into the first row instead of
        // being an extra item.
        return [
          for (var i = 0; i < spots.length; i++)
            if (spots[i].barIndex < 0 ||
                spots[i].barIndex >= entries.length)
              LineTooltipItem(
                '',
                AppText.mono.copyWith(
                    fontSize: 10, color: Colors.transparent),
              )
            else
              LineTooltipItem(
                '${i == 0 ? '${formatX(spots[i].x)}\n' : ''}'
                '${entries[spots[i].barIndex].$1.toUpperCase()}  '
                '${formatY(spots[i].y)}$suffix',
                AppText.mono.copyWith(
                  fontSize: 11.5,
                  fontWeight: FontWeight.w700,
                  color: entries[spots[i].barIndex].$2,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
                textAlign: TextAlign.left,
              ),
        ];
      },
    ),
  );
}

/// Live time-series line chart fed from [telemetryStoreProvider].
///
/// Live, the horizontal axis is *seconds in the past*: `-60` on the left,
/// `0` (now) on the right. "Now" is the wall clock during a live session and
/// the replay clock during a replay — so the chart keeps scrolling smoothly
/// even when no packets arrive.
///
/// During a replay the chart switches to whole-flight mode: the axis spans
/// the entire recording from 0 and counts up, with y bounds fixed to the
/// full flight so nothing rescales while the replay progresses.
class TimeSeriesChart extends ConsumerStatefulWidget {
  final TimeSeriesConfig config;

  const TimeSeriesChart({super.key, required this.config});

  @override
  ConsumerState<TimeSeriesChart> createState() => _TimeSeriesChartState();
}

class _TimeSeriesChartState extends ConsumerState<TimeSeriesChart> {
  static const int _maxPoints = 400;

  /// Drives the smooth scroll of the time axis between packet arrivals.
  Timer? _ticker;

  /// Whole-flight y-bounds cache, keyed by the replay frames list identity
  /// (the list is fixed for the whole replay, so this computes once).
  List<TelemetryFrame>? _boundsSource;
  (double, double)? _boundsCache;

  @override
  void initState() {
    super.initState();
    _ticker = Timer.periodic(const Duration(milliseconds: 200), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  /// Min/max of every series across the entire recording.
  (double, double) _fullFlightBounds(List<TelemetryFrame> frames) {
    if (!identical(frames, _boundsSource)) {
      var lo = double.infinity;
      var hi = double.negativeInfinity;
      for (final frame in frames) {
        for (final spec in widget.config.series) {
          final v = spec.value(frame);
          if (v < lo) lo = v;
          if (v > hi) hi = v;
        }
      }
      _boundsSource = frames;
      _boundsCache = (lo.isFinite ? lo : 0.0, hi.isFinite ? hi : 1.0);
    }
    return _boundsCache!;
  }

  @override
  Widget build(BuildContext context) {
    final store = ref.watch(telemetryStoreProvider);
    final replay = ref.watch(replayProvider);
    final history = store.history;

    // During a replay the whole recording is known up front: the chart shows
    // the entire flight on a fixed 0..duration axis (seconds since launch)
    // with y bounds from the full flight. Live keeps the rolling window.
    final replayFrames = store.replaying && replay.isActive
        ? replay.frames
        : const <TelemetryFrame>[];
    final fullFlight = replayFrames.length >= 2;

    // "Now" in packet-time: wall clock live, replay clock during replay.
    final nowMs = store.replaying && replay.isActive
        ? (store.firstPacketMs ?? 0) + replay.positionMs
        : DateTime.now().millisecondsSinceEpoch;
    final originMs = fullFlight ? replayFrames.first.receivedAtMs : nowMs;
    final windowMs = fullFlight
        ? math.max(1, replayFrames.last.receivedAtMs - originMs)
        : widget.config.window.inMilliseconds;
    final windowStart = nowMs - windowMs;

    // Window filter + decimation. Points are bucketed by *absolute* packet
    // time, so the sampled set is stable while the window slides — the line
    // no longer flickers once data reaches the left edge.
    // In replay the whole flight is shown: samples up to the replay clock at
    // full opacity, the not-yet-played remainder dimmed.
    final bucketMs = math.max(1, windowMs ~/ _maxPoints);
    final playedSamples = <TelemetryFrame>[];
    final futureSamples = <TelemetryFrame>[];
    if (fullFlight) {
      var lastPlayedBucket = -1;
      var lastFutureBucket = -1;
      TelemetryFrame? lastPlayed;
      for (final frame in replayFrames) {
        final t = frame.receivedAtMs;
        final bucket = t ~/ bucketMs;
        if (t <= nowMs) {
          if (bucket == lastPlayedBucket) continue;
          playedSamples.add(frame);
          lastPlayedBucket = bucket;
          lastPlayed = frame;
        } else {
          if (bucket == lastFutureBucket) continue;
          // Carry the last played point so the dimmed segment connects.
          if (futureSamples.isEmpty && lastPlayed != null) {
            futureSamples.add(lastPlayed);
            lastFutureBucket = lastPlayed.receivedAtMs ~/ bucketMs;
            if (bucket == lastFutureBucket) continue;
          }
          futureSamples.add(frame);
          lastFutureBucket = bucket;
        }
      }
    } else {
      var lastBucket = -1;
      final len = history.length;
      for (var i = 0; i < len; i++) {
        final frame = history.getChronological(i);
        final t = frame.receivedAtMs;
        if (t < windowStart || t > nowMs) continue;
        final bucket = t ~/ bucketMs;
        if (bucket == lastBucket) continue;
        playedSamples.add(frame);
        lastBucket = bucket;
      }
    }
    final samples = fullFlight
        ? [
            ...playedSamples,
            ...futureSamples.skip(playedSamples.isEmpty ? 0 : 1),
          ]
        : playedSamples;

    List<FlSpot> spotsFor(List<TelemetryFrame> frames, SeriesSpec spec) => [
      for (final frame in frames)
        FlSpot((frame.receivedAtMs - originMs) / 1000, spec.value(frame)),
    ];

    // Auto y-range snapped to round values so gridlines and ticks stay clean
    // (e.g. velocity hovering at 0 gets a -0.5..0.5 axis, not -0.37..0.41).
    // During a replay the bounds come from the whole recording, so the axis
    // never rescales while the flight plays back.
    var rawMin = widget.config.yMin ?? double.infinity;
    var rawMax = widget.config.yMax ?? double.negativeInfinity;
    if (widget.config.yMin == null || widget.config.yMax == null) {
      if (fullFlight) {
        final (lo, hi) = _fullFlightBounds(replayFrames);
        if (widget.config.yMin == null) rawMin = lo;
        if (widget.config.yMax == null) rawMax = hi;
      } else {
        for (final frame in samples) {
          for (final spec in widget.config.series) {
            final v = spec.value(frame);
            if (widget.config.yMin == null && v < rawMin) rawMin = v;
            if (widget.config.yMax == null && v > rawMax) rawMax = v;
          }
        }
      }
      if (rawMin == double.infinity) rawMin = 0;
      if (rawMax == double.negativeInfinity) rawMax = 1;
      // Include zero baseline when it is close to the data range.
      if (rawMin > 0 && rawMin < (rawMax - rawMin) * 0.5) rawMin = 0;
      if (rawMax < 0 && -rawMax < (rawMax - rawMin).abs() * 0.5) rawMax = 0;
    }
    // Flat data (e.g. hall raw sitting at its pad value) would collapse the
    // axis to zero height and a zero grid interval — open it around the value.
    if ((rawMax - rawMin).abs() < 1e-9) {
      final v = (rawMin + rawMax) / 2;
      final pad = math.max(v.abs() * 0.05, 1.0);
      rawMin = v - pad;
      rawMax = v + pad;
    }
    final yStep = _niceStep(((rawMax - rawMin).abs()) / 3);
    final minY = widget.config.yMin ?? (rawMin / yStep).floorToDouble() * yStep;
    final maxY = widget.config.yMax ?? (rawMax / yStep).ceilToDouble() * yStep;
    final ySpan = maxY - minY;
    final yInterval = ySpan <= 0
        ? yStep
        : ySpan / ((ySpan / yStep).round().clamp(2, 6));

    // Tooltip legend kept 1:1 with [lineBars] (replay duplicates included)
    // so the touched bar index always resolves its row.
    final lineBars = <LineChartBarData>[];
    final legend = <(String, Color)>[];
    for (var i = 0; i < widget.config.series.length; i++) {
      final spec = widget.config.series[i];
      lineBars.add(
        LineChartBarData(
          spots: spotsFor(playedSamples, spec),
          color: spec.color,
          barWidth: 1.6,
          // Raw data — no smoothing/filtering.
          isCurved: false,
          dotData: const FlDotData(show: false),
          dashArray: spec.dashed ? [5, 4] : null,
          // Subtle area fill under single-series charts (played part only).
          belowBarData: widget.config.series.length == 1
              ? BarAreaData(
                  show: true,
                  color: spec.color.withValues(alpha: 0.08),
                )
              : BarAreaData(show: false),
        ),
      );
      legend.add((spec.label, spec.color));
      if (fullFlight) {
        lineBars.add(
          LineChartBarData(
            spots: spotsFor(futureSamples, spec),
            color: spec.color.withValues(alpha: 0.25),
            barWidth: 1.6,
            isCurved: false,
            dotData: const FlDotData(show: false),
            dashArray: spec.dashed ? [5, 4] : null,
            belowBarData: BarAreaData(show: false),
          ),
        );
        legend.add((spec.label, spec.color));
      }
    }

    final xInterval = _timeInterval(windowMs / 1000);
    // Left/right edge of the axis in packet-time: the rolling window live,
    // the whole 0..duration flight during a replay.
    final axisStartMs = fullFlight ? originMs : windowStart;
    final axisEndMs = fullFlight ? originMs + windowMs : nowMs;

    // Display-only plot repainting on a 200 ms ticker (plus live data):
    // excluded from semantics so axis labels don't churn the Windows
    // accessibility bridge (see CenteredValue). The chart has no
    // interactive elements; tile headers stay readable.
    return ExcludeSemantics(
      child: LayoutBuilder(
        builder: (context, constraints) {
          // Short tiles give the plot priority: the legend collapses away
          // below ~120 px so the line keeps room to breathe.
          final showLegend =
              widget.config.showLegend && constraints.maxHeight >= 120;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Legend.
              if (showLegend)
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Wrap(
                    spacing: 12,
                    runSpacing: 4,
                    children: [
                      for (final spec in widget.config.series)
                        FittedBox(
                          fit: BoxFit.scaleDown,
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Container(
                                width: 12,
                                height: 2.5,
                                decoration: BoxDecoration(
                                  color: spec.color,
                                  borderRadius: BorderRadius.circular(2),
                                ),
                              ),
                              const SizedBox(width: 5),
                              Text(
                                spec.label.toUpperCase(),
                                style: AppText.microLabel.copyWith(
                                  fontSize: 9,
                                  letterSpacing: 0.8,
                                  color: AppColors.mutedForeground,
                                ),
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
                ),
              Expanded(
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    LineChart(
                      LineChartData(
                        minX: (axisStartMs - originMs) / 1000,
                        maxX: (axisEndMs - originMs) / 1000,
                        minY: minY,
                        maxY: maxY,
                        gridData: FlGridData(
                          show: true,
                          drawVerticalLine: true,
                          verticalInterval: xInterval,
                          horizontalInterval: yInterval,
                          getDrawingHorizontalLine: (value) => FlLine(
                            color: value == 0
                                ? AppColors.strongBorder
                                : AppColors.border,
                            strokeWidth: 1,
                          ),
                          getDrawingVerticalLine: (value) => FlLine(
                            color: value == 0
                                ? AppColors.strongBorder
                                : AppColors.border,
                            strokeWidth: 1,
                          ),
                        ),
                        borderData: FlBorderData(
                          show: true,
                          border: Border(
                            left: BorderSide(color: AppColors.border),
                            bottom: BorderSide(color: AppColors.border),
                          ),
                        ),
                        titlesData: FlTitlesData(
                          topTitles: const AxisTitles(
                            sideTitles: SideTitles(showTitles: false),
                          ),
                          rightTitles: const AxisTitles(
                            sideTitles: SideTitles(showTitles: false),
                          ),
                          leftTitles: AxisTitles(
                            sideTitles: SideTitles(
                              showTitles: widget.config.showLeftAxis,
                              reservedSize: widget.config.showLeftAxis ? 42 : 0,
                              interval: yInterval,
                              getTitlesWidget: (value, meta) => SideTitleWidget(
                                meta: meta,
                                child: Text(
                                  _formatValue(value),
                                  style: AppText.mono.copyWith(
                                    fontSize: 9.5,
                                    color: AppColors.faint,
                                  ),
                                ),
                              ),
                            ),
                          ),
                          bottomTitles: AxisTitles(
                            sideTitles: SideTitles(
                              showTitles: true,
                              reservedSize: 18,
                              interval: xInterval,
                              getTitlesWidget: (value, meta) => SideTitleWidget(
                                meta: meta,
                                child: Text(
                                  '${value.toStringAsFixed(0)}s',
                                  style: AppText.mono.copyWith(
                                    fontSize: 9.5,
                                    color: AppColors.faint,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                        lineTouchData: chartTouchData(
                          entries: legend,
                          unit: widget.config.unit,
                          formatX: (x) => '${x.toStringAsFixed(0)}s',
                          formatY: _formatValue,
                        ),
                        lineBarsData: lineBars,
                      ),
                      duration: Duration.zero,
                    ),
                    if (samples.isEmpty)
                      const Center(child: WaitingForData(compact: true)),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  /// Chooses a human-friendly axis step (1-2-5 progression).
  double _niceStep(double raw) {
    if (raw <= 0) return 1;
    var mag = 1.0;
    while (raw < mag) {
      mag /= 10;
    }
    while (raw >= mag * 10) {
      mag *= 10;
    }
    for (final m in [1.0, 2.0, 5.0, 10.0]) {
      if (raw <= m * mag) return m * mag;
    }
    return 10 * mag;
  }

  double _timeInterval(double seconds) {
    if (seconds <= 15) return 5;
    if (seconds <= 30) return 10;
    if (seconds <= 60) return 15;
    if (seconds <= 150) return 30;
    return (seconds / 5).roundToDouble();
  }

  String _formatValue(double v) {
    if (v.abs() >= 1000) return v.toStringAsFixed(0);
    if (v.abs() >= 100) return v.toStringAsFixed(1);
    if (v.abs() >= 10) return v.toStringAsFixed(1);
    return v.toStringAsFixed(2);
  }
}
