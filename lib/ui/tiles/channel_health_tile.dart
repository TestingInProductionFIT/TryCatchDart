import 'dart:async';
import 'dart:math' as math;

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/replay_controller.dart';
import '../../core/channel_health.dart';
import '../../core/format.dart';
import '../../state/channel_health_provider.dart';
import '../../state/telemetry_provider.dart';
import '../../state/telemetry_store.dart';
import '../../theme/app_colors.dart';
import '../components/app_card.dart';
import '../components/centered_stat.dart';
import '../components/waiting_for_data.dart';
import './shared/time_series_chart.dart'
    show chartTouchData, previewBarAlpha;

/// Tile-friendly channel-health readout: verdict + rolling signal chart.
///
/// The workspace grid wraps every tile in an [AppCard], so this renders
/// no background, no max-width constraint and no nested card. Very short
/// tiles shed the chart and show just the headline interference number.
class ChannelHealthTile extends ConsumerStatefulWidget {
  const ChannelHealthTile({super.key});

  @override
  ConsumerState<ChannelHealthTile> createState() => _ChannelHealthTileState();
}

class _ChannelHealthTileState extends ConsumerState<ChannelHealthTile> {
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    // Repaint on a steady cadence so the live window scrolls even in silence.
    _ticker = Timer.periodic(const Duration(milliseconds: 500), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Shared history: survives remounts (notably the edit-mode toggle,
    // which swaps wrappers around every tile and recreates tile State).
    ref.watch(channelHealthProvider);
    final tracker = ref.read(channelHealthProvider.notifier).tracker;
    final status = ref.watch(serialStatusProvider).value;
    final connected = status?.isConnected ?? false;
    final replay = ref.watch(replayProvider);
    final store = ref.watch(telemetryStoreProvider);

    // Whole-flight replay view, mirroring TimeSeriesChart.
    final profile = store.replaying && replay.isActive
        ? replay.channelProfile
        : const <ChannelBin>[];
    if (profile.length >= 2) {
      return _TileReplayBody(
        profile: profile,
        positionMs: replay.positionMs,
      );
    }

    if (!connected) {
      return const Center(
        child: WaitingForData(
          compact: true,
          hint: 'Connect a port to scan, or replay a flight',
        ),
      );
    }

    final latest = tracker.latest;
    final matchedBps = latest?.matchedBps ?? 0.0;
    final unmatchedBps = latest?.unmatchedBps ?? 0.0;
    final verdict = verdictFor(unmatchedBps);

    return LayoutBuilder(
      builder: (context, constraints) {
        // Very short tiles drop the graph and show the live number.
        if (constraints.maxHeight.isFinite && constraints.maxHeight < 110) {
          if (latest == null) {
            return const Center(child: WaitingForData(compact: true));
          }
          return Center(
            child: CenteredValue(
              value: formatBps(unmatchedBps),
              valueColor: _verdictColor(verdict),
              sublabel: '${_verdictLabel(verdict)} · UNKNOWN',
            ),
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _TileVerdictRow(
              verdict: verdict,
              matchedBps: matchedBps,
              unmatchedBps: unmatchedBps,
            ),
            const SizedBox(height: 6),
            Expanded(child: _RateChart(tracker: tracker)),
          ],
        );
      },
    );
  }
}

/// Compact whole-flight replay body for the tile: verdict row + chart with
/// the played segment at full opacity and the remainder dimmed.
class _TileReplayBody extends StatelessWidget {
  final List<ChannelBin> profile;
  final int positionMs;

  const _TileReplayBody({
    required this.profile,
    required this.positionMs,
  });

  @override
  Widget build(BuildContext context) {
    final played = <ChannelBin>[];
    final future = <ChannelBin>[];
    for (final bin in profile) {
      if (bin.startMs <= positionMs) {
        played.add(bin);
      } else {
        if (future.isEmpty && played.isNotEmpty) future.add(played.last);
        future.add(bin);
      }
    }
    final cursor = played.isEmpty ? null : played.last;
    final verdict = verdictFor(cursor?.unmatchedBps ?? 0.0);

    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxHeight.isFinite && constraints.maxHeight < 110) {
          return Center(
            child: CenteredValue(
              value: formatBps(cursor?.unmatchedBps ?? 0.0),
              valueColor: _verdictColor(verdict),
              sublabel: '${_verdictLabel(verdict)} · UNKNOWN',
            ),
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _TileVerdictRow(
              verdict: verdict,
              matchedBps: cursor?.matchedBps ?? 0.0,
              unmatchedBps: cursor?.unmatchedBps ?? 0.0,
            ),
            const SizedBox(height: 6),
            Expanded(
              child: _ReplayChart(
                played: played,
                future: future,
                profile: profile,
                durationMs: null,
                positionMs: positionMs,
              ),
            ),
          ],
        );
      },
    );
  }
}

/// Single-line verdict header for the tile: colored dot + verdict name on
/// the left, ours-vs-unknown rates on the right (ellipsized in narrow
/// tiles).
class _TileVerdictRow extends StatelessWidget {
  final ChannelVerdict verdict;
  final double matchedBps;
  final double unmatchedBps;

  const _TileVerdictRow({
    required this.verdict,
    required this.matchedBps,
    required this.unmatchedBps,
  });

  @override
  Widget build(BuildContext context) {
    final color = _verdictColor(verdict);
    return Row(
      children: [
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 6),
        Text(
          _verdictLabel(verdict),
          style: AppText.microLabel.copyWith(
            fontSize: 10,
            letterSpacing: 0.8,
            color: color,
          ),
        ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '${matchedBps.round()} ours · '
              '${unmatchedBps.round()} unknown B/s',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.right,
              style: AppText.mono.copyWith(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                fontFeatures: const [FontFeature.tabularFigures()],
                color: AppColors.mutedForeground,
              ),
            ),
          ),
        ],
      );
  }
}

Color _verdictColor(ChannelVerdict verdict) => switch (verdict) {
      ChannelVerdict.clear => AppColors.success,
      ChannelVerdict.activity => AppColors.warning,
      ChannelVerdict.interference => AppColors.destructive,
    };

String _verdictLabel(ChannelVerdict verdict) => switch (verdict) {
      ChannelVerdict.clear => 'CLEAR',
      ChannelVerdict.activity => 'ACTIVITY',
      ChannelVerdict.interference => 'INTERFERENCE',
    };

class _RateChart extends StatelessWidget {
  final ChannelHealthTracker tracker;

  const _RateChart({required this.tracker});

  /// Rolling live window (ms) for the tile chart.
  static const _windowMs = 60000;

  @override
  Widget build(BuildContext context) {
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final cutoff = nowMs - _windowMs;
    final points = <ChannelSample>[
      for (final s in tracker.samples.newestFirst())
        if (s.timestampMs >= cutoff) s,
    ].reversed.toList();

    if (points.length < 2) {
      return const Center(child: WaitingForData(compact: true));
    }

    List<FlSpot> spots(double Function(ChannelSample) pick) => [
          for (final s in points)
            FlSpot((s.timestampMs - cutoff) / 1000, pick(s)),
        ];

    var peak = 1.0;
    for (final s in points) {
      peak = math.max(peak, math.max(s.matchedBps, s.unmatchedBps));
    }
    final maxY = _snappedMax(peak);

    return LineChart(
      _chartData(
        minX: 0,
        maxX: _windowMs / 1000,
        maxY: maxY,
        played: [
          _bar(spots((s) => s.matchedBps), AppColors.success),
          _bar(spots((s) => s.unmatchedBps), AppColors.destructive,
              fill: true),
        ],
        touchData: chartTouchData(
          entries: [
            ('OURS', AppColors.success),
            ('UNKNOWN', AppColors.destructive),
          ],
          unit: 'B/s',
          formatX: (value) =>
              '${(60 - value).toStringAsFixed(0)}s ago',
          formatY: (value) => value.round().toString(),
        ),
        bottomLabel: (value) => '-${(60 - value).toStringAsFixed(0)}s',
      ),
      duration: Duration.zero,
    );
  }
}

/// Whole-flight replay chart: x counts up 0…duration in M:SS, played segment
/// full opacity + remainder dimmed (same language as [TimeSeriesChart]).
class _ReplayChart extends StatelessWidget {
  final List<ChannelBin> played;
  final List<ChannelBin> future;
  final List<ChannelBin> profile;
  final int? durationMs;
  final int positionMs;

  const _ReplayChart({
    required this.played,
    required this.future,
    required this.profile,
    required this.durationMs,
    required this.positionMs,
  });

  @override
  Widget build(BuildContext context) {
    if (profile.length < 2) {
      return const Center(child: WaitingForData(compact: true));
    }

    List<FlSpot> spots(List<ChannelBin> bins, double Function(ChannelBin) pick) => [
          for (final b in bins) FlSpot(b.startMs / 1000, pick(b)),
        ];

    var peak = 1.0;
    for (final b in profile) {
      peak = math.max(peak, math.max(b.matchedBps, b.unmatchedBps));
    }
    final maxY = _snappedMax(peak);

    final binMs = profile.length > 1
        ? profile[1].startMs - profile[0].startMs
        : 500;
    final profileEndS = (profile.last.startMs + binMs) / 1000;
    final durationS = (durationMs ?? 0) / 1000;
    // durationMs is null for the tile (playhead-only view): fall back to the
    // profile extent so the axis still spans the whole flight.
    final double maxX =
        math.max(durationS > 0 ? durationS : 0.0, profileEndS);

    LineChartBarData dimmed(List<FlSpot> s, Color c) => _bar(
          s,
          c.withValues(alpha: previewBarAlpha),
        );

    // X axis: clock-friendly M:SS steps so long flights don't pile dozens
    // of overlapping texts (the old 1-2-5 step landed on e.g. 8:20).
    final xStep = replayXInterval(math.max(1.0, maxX));
    final chartMaxX = math.max(1.0, maxX);
    final playheadX =
        (positionMs / 1000).clamp(0.0, chartMaxX).toDouble();

    // Tooltip legend kept 1:1 with the bars (played + dimmed future +
    // invisible per-series touch bars, in that order) so the touched bar
    // index always resolves its row. Touch runs only on the transparent
    // touch bars over the unified bins (no junction duplicate): one match
    // per series on either side of the playhead — never twins, never
    // sticking. See [chartTouchData].
    final touchBins = [
      ...played,
      ...future.skip(played.isEmpty ? 0 : 1),
    ];
    List<FlSpot> touchSpots(double Function(ChannelBin) pick) => [
          for (final b in touchBins) FlSpot(b.startMs / 1000, pick(b)),
        ];
    LineChartBarData touchBar(List<FlSpot> s, Color c) => _bar(
          s,
          c.withValues(alpha: 0),
        );
    return LineChart(
      _chartData(
        minX: 0,
        maxX: chartMaxX,
        maxY: maxY,
        bottomInterval: xStep,
        playheadX: playheadX,
        played: [
          _bar(spots(played, (b) => b.matchedBps), AppColors.success),
          _bar(spots(played, (b) => b.unmatchedBps), AppColors.destructive,
              fill: true),
        ],
        future: [
          dimmed(spots(future, (b) => b.matchedBps), AppColors.success),
          dimmed(
              spots(future, (b) => b.unmatchedBps), AppColors.destructive),
        ],
        touch: [
          touchBar(
              touchSpots((b) => b.matchedBps), AppColors.success),
          touchBar(
              touchSpots((b) => b.unmatchedBps), AppColors.destructive),
        ],
        touchData: chartTouchData(
          entries: [
            ('OURS', AppColors.success),
            ('UNKNOWN', AppColors.destructive),
            ('OURS', AppColors.success),
            ('UNKNOWN', AppColors.destructive),
            ('OURS', AppColors.success),
            ('UNKNOWN', AppColors.destructive),
          ],
          unit: 'B/s',
          formatX: (value) => formatAxisMinSec(value),
          formatY: (value) => value.round().toString(),
          touchBarsOnly: true,
        ),
        bottomLabel: (value) => formatAxisMinSec(value),
      ),
      duration: Duration.zero,
    );
  }
}

LineChartBarData _bar(List<FlSpot> spots, Color color, {bool fill = false}) =>
    LineChartBarData(
      spots: spots,
      color: color,
      barWidth: 1.6,
      isCurved: false,
      dotData: const FlDotData(show: false),
      belowBarData: fill
          ? BarAreaData(show: true, color: color.withValues(alpha: 0.08))
          : BarAreaData(show: false),
    );

LineChartData _chartData({
  required double minX,
  required double maxX,
  required double maxY,
  required List<LineChartBarData> played,
  List<LineChartBarData>? future,
  List<LineChartBarData> touch = const [],
  required LineTouchData touchData,
  required String Function(double) bottomLabel,
  double? bottomInterval,
  double? playheadX,
}) {
  final step = _niceStep(maxY / 3);
  final interval = maxY / (maxY / step).round().clamp(2, 6);
  final xInterval = bottomInterval ?? 15;
  return LineChartData(
    minX: minX,
    maxX: maxX,
    minY: 0,
    maxY: maxY,
    extraLinesData: playheadX == null
        ? const ExtraLinesData()
        : ExtraLinesData(
            verticalLines: [
              VerticalLine(
                x: playheadX,
                color: AppColors.mutedForeground,
                strokeWidth: 1.2,
                dashArray: [5, 4],
              ),
            ],
          ),
    gridData: FlGridData(
      show: true,
      drawVerticalLine: true,
      verticalInterval: xInterval,
      horizontalInterval: interval,
      getDrawingHorizontalLine: (value) => FlLine(
        color: AppColors.border,
        strokeWidth: 1,
      ),
      getDrawingVerticalLine: (value) => FlLine(
        color: AppColors.border,
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
      topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
      rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
      leftTitles: AxisTitles(
        sideTitles: SideTitles(
          showTitles: true,
          reservedSize: 48,
          interval: interval,
          getTitlesWidget: (value, meta) => SideTitleWidget(
            meta: meta,
            child: Text(
              _axisLabel(value),
              style: AppText.mono
                  .copyWith(fontSize: 9.5, color: AppColors.faint),
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
              bottomLabel(value),
              style: AppText.mono
                  .copyWith(fontSize: 9.5, color: AppColors.faint),
            ),
          ),
        ),
      ),
    ),
    lineTouchData: touchData,
    lineBarsData: [...played, ...?future, ...touch],
  );
}

/// Snaps [peak] up to a round axis max (1-2-5 progression).
double _snappedMax(double peak) {
  final step = _niceStep(peak / 3);
  return (peak / step).ceilToDouble() * step;
}

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

String _axisLabel(double v) {
  if (v >= 1000) return '${(v / 1000).toStringAsFixed(1)}k';
  return v.toStringAsFixed(0);
}
