import 'dart:async';
import 'dart:math' as math;

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:serial/serial.dart';

import '../flights/replay_controller.dart';
import '../src/telemetry/channel_health.dart';
import '../src/telemetry/telemetry_provider.dart';
import '../src/telemetry/telemetry_store.dart';
import '../theme/app_colors.dart';
import '../theme/widgets/app_card.dart';
import '../theme/widgets/status_pill.dart';
import '../theme/widgets/waiting_for_data.dart';

/// Channel-health monitor: shows how much radio traffic on our frequency
/// does NOT decode as our packets (other teams, noise).
///
/// Live, rates come from cumulative [LinkStats] snapshots emitted by the
/// serial worker (~2 Hz) and plot as a rolling 60 s window. During a replay
/// the widget switches to whole-flight mode like the other charts: the
/// recording's raw chunks (garbage included) were bucketed into
/// [ChannelBin]s at load, so the full flight shows with the played segment
/// at full opacity and the remainder dimmed. Use before launch to check the
/// frequency is free.
class ChannelHealthMonitor extends ConsumerStatefulWidget {
  const ChannelHealthMonitor({super.key});

  @override
  ConsumerState<ChannelHealthMonitor> createState() =>
      _ChannelHealthMonitorState();
}

class _ChannelHealthMonitorState extends ConsumerState<ChannelHealthMonitor> {
  final ChannelHealthTracker _tracker = ChannelHealthTracker();
  LinkStats _totals = LinkStats.empty;
  Timer? _ticker;

  static const _windowMs = 60000;

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
    ref.listen(linkStatsStreamProvider, (_, next) {
      next.whenData((stats) {
        _totals = stats;
        _tracker.addSnapshot(stats);
        if (mounted) setState(() {});
      });
    });
    final status = ref.watch(serialStatusProvider).value;
    final connected = status?.isConnected ?? false;
    final replay = ref.watch(replayProvider);
    final store = ref.watch(telemetryStoreProvider);

    // Whole-flight replay view, mirroring TimeSeriesChart.
    final profile = store.replaying && replay.isActive
        ? replay.channelProfile
        : const <ChannelBin>[];
    if (profile.length >= 2) {
      return _ReplayBody(
        profile: profile,
        positionMs: replay.positionMs,
        durationMs: replay.durationMs,
      );
    }

    if (!connected) {
      return Container(
        color: AppColors.background,
        padding: const EdgeInsets.all(16),
        child: const Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              WaitingForData(),
              SizedBox(height: 8),
              Text(
                'Connect a port to scan the frequency, or replay a flight.\n'
                'Unmatched bytes/s shows traffic that is not our packets.',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 12),
              ),
            ],
          ),
        ),
      );
    }

    final latest = _tracker.latest;
    final unmatchedBps = latest?.unmatchedBps ?? 0.0;
    final verdict = verdictFor(unmatchedBps);
    final share = _totals.totalBytes > 0
        ? _totals.unmatchedBytes / _totals.totalBytes
        : 0.0;

    return Container(
      color: AppColors.background,
      padding: const EdgeInsets.all(16),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1100),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _VerdictBanner(
                verdict: verdict,
                unmatchedBps: unmatchedBps,
                share: share,
                crcErrors: _totals.crcErrors,
              ),
              const SizedBox(height: 12),
              Expanded(
                child: AppCard(
                  title: 'Bytes/s on this frequency',
                  subtitle: 'rolling 60 s',
                  trailing: _Legend(),
                  fillChild: true,
                  child: _RateChart(tracker: _tracker),
                ),
              ),
              const SizedBox(height: 12),
              _StatsRow(cards: [
                ('OURS NOW', formatBps(latest?.matchedBps ?? 0)),
                ('UNMATCHED NOW', formatBps(latest?.unmatchedBps ?? 0)),
                ('TOTAL NOW', formatBps(latest?.totalBps ?? 0)),
                (
                  'OUR PACKETS',
                  '${latest?.packetRate.toStringAsFixed(1) ?? '—'} pkt/s'
                ),
                ('BYTES TOTAL', _compactBytes(_totals.totalBytes)),
                ('MATCHED PKTS', '${_totals.matchedPackets}'),
              ]),
            ],
          ),
        ),
      ),
    );
  }
}

/// Whole-flight replay body: played segment at full opacity, remainder
/// dimmed; verdict and totals follow the playhead.
class _ReplayBody extends StatelessWidget {
  final List<ChannelBin> profile;
  final int positionMs;
  final int? durationMs;

  const _ReplayBody({
    required this.profile,
    required this.positionMs,
    required this.durationMs,
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

    var cumMatched = 0;
    var cumUnmatched = 0;
    var cumPackets = 0;
    var cumCrcs = 0;
    for (final bin in played) {
      cumMatched += bin.matchedBytes;
      cumUnmatched += bin.unmatchedBytes;
      cumPackets += bin.matchedPackets;
      cumCrcs += bin.crcErrors;
    }
    final share = (cumMatched + cumUnmatched) > 0
        ? cumUnmatched / (cumMatched + cumUnmatched)
        : 0.0;
    final verdict = verdictFor(cursor?.unmatchedBps ?? 0.0);

    return Container(
      color: AppColors.background,
      padding: const EdgeInsets.all(16),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1100),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _VerdictBanner(
                verdict: verdict,
                unmatchedBps: cursor?.unmatchedBps ?? 0.0,
                share: share,
                crcErrors: cumCrcs,
              ),
              const SizedBox(height: 12),
              Expanded(
                child: AppCard(
                  title: 'Bytes/s on this frequency',
                  subtitle: 'whole flight · replay',
                  trailing: _Legend(),
                  fillChild: true,
                  child: _ReplayChart(
                    played: played,
                    future: future,
                    profile: profile,
                    durationMs: durationMs,
                  ),
                ),
              ),
              const SizedBox(height: 12),
              _StatsRow(cards: [
                ('OURS @ CURSOR', formatBps(cursor?.matchedBps ?? 0)),
                ('UNMATCHED @ CURSOR', formatBps(cursor?.unmatchedBps ?? 0)),
                ('TOTAL @ CURSOR', formatBps(cursor?.totalBps ?? 0)),
                (
                  'OUR PACKETS',
                  '${cursor?.packetRate.toStringAsFixed(1) ?? '—'} pkt/s'
                ),
                ('BYTES SO FAR', _compactBytes(cumMatched + cumUnmatched)),
                ('MATCHED PKTS', '$cumPackets'),
              ]),
            ],
          ),
        ),
      ),
    );
  }
}

class _VerdictBanner extends StatelessWidget {
  final ChannelVerdict verdict;
  final double unmatchedBps;
  final double share;
  final int crcErrors;

  const _VerdictBanner({
    required this.verdict,
    required this.unmatchedBps,
    required this.share,
    required this.crcErrors,
  });

  @override
  Widget build(BuildContext context) {
    final (label, color, hint) = switch (verdict) {
      ChannelVerdict.clear => (
          'Channel clear',
          AppColors.success,
          'No foreign traffic — the frequency looks free.',
        ),
      ChannelVerdict.activity => (
          'Some activity',
          AppColors.warning,
          'Stray bytes on this frequency — watch it before launch.',
        ),
      ChannelVerdict.interference => (
          'Interference',
          AppColors.destructive,
          'Sustained traffic that is not ours — consider changing frequency.',
        ),
    };
    return AppCard(
      child: Row(
        children: [
          StatusPill(
            label: label,
            color: color,
            pulsing: verdict != ChannelVerdict.clear,
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  '${formatBps(unmatchedBps)} unmatched',
                  style: AppText.monoValue.copyWith(fontSize: 16),
                ),
                const SizedBox(height: 2),
                Text(
                  hint,
                  style:
                      TextStyle(fontSize: 12, color: AppColors.mutedForeground),
                ),
              ],
            ),
          ),
          const SizedBox(width: 16),
          _TotalStat(
            label: 'UNMATCHED SHARE',
            value: '${(share * 100).toStringAsFixed(1)} %',
          ),
          const SizedBox(width: 20),
          _TotalStat(
            label: 'CRC ERRORS',
            value: '$crcErrors',
          ),
        ],
      ),
    );
  }
}

class _TotalStat extends StatelessWidget {
  final String label;
  final String value;

  const _TotalStat({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(label, style: AppText.microLabel.copyWith(fontSize: 9)),
        const SizedBox(height: 2),
        Text(value, style: AppText.monoValue.copyWith(fontSize: 14)),
      ],
    );
  }
}

class _Legend extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _swatch(AppColors.success, 'OURS'),
        const SizedBox(width: 10),
        _swatch(AppColors.destructive, 'UNMATCHED'),
        const SizedBox(width: 10),
        _swatch(AppColors.faint, 'TOTAL'),
      ],
    );
  }

  Widget _swatch(Color color, String label) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 12,
          height: 2.5,
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(2),
          ),
        ),
        const SizedBox(width: 5),
        Text(
          label,
          style: AppText.microLabel.copyWith(
            fontSize: 9,
            letterSpacing: 0.8,
            color: AppColors.mutedForeground,
          ),
        ),
      ],
    );
  }
}

class _RateChart extends StatelessWidget {
  final ChannelHealthTracker tracker;

  const _RateChart({required this.tracker});

  @override
  Widget build(BuildContext context) {
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final cutoff = nowMs - _ChannelHealthMonitorState._windowMs;
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
      peak = math.max(peak, math.max(s.totalBps, s.unmatchedBps));
      peak = math.max(peak, s.matchedBps);
    }
    final maxY = _snappedMax(peak);

    return LineChart(
      _chartData(
        minX: 0,
        maxX: _ChannelHealthMonitorState._windowMs / 1000,
        maxY: maxY,
        played: [
          _bar(spots((s) => s.totalBps), AppColors.faint),
          _bar(spots((s) => s.matchedBps), AppColors.success),
          _bar(spots((s) => s.unmatchedBps), AppColors.destructive,
              fill: true),
        ],
        bottomLabel: (value) => '-${(60 - value).toStringAsFixed(0)}s',
      ),
      duration: Duration.zero,
    );
  }
}

/// Whole-flight replay chart: x counts up 0…duration, played segment full
/// opacity + remainder dimmed (same language as [TimeSeriesChart]).
class _ReplayChart extends StatelessWidget {
  final List<ChannelBin> played;
  final List<ChannelBin> future;
  final List<ChannelBin> profile;
  final int? durationMs;

  const _ReplayChart({
    required this.played,
    required this.future,
    required this.profile,
    required this.durationMs,
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
      peak = math.max(peak, math.max(b.totalBps, b.unmatchedBps));
      peak = math.max(peak, b.matchedBps);
    }
    final maxY = _snappedMax(peak);

    final binMs = profile.length > 1
        ? profile[1].startMs - profile[0].startMs
        : 500;
    final profileEndS = (profile.last.startMs + binMs) / 1000;
    final maxX = math.max((durationMs ?? 0) / 1000, profileEndS);

    LineChartBarData dimmed(List<FlSpot> s, Color c) => _bar(
          s,
          c.withValues(alpha: 0.25),
        );

    return LineChart(
      _chartData(
        minX: 0,
        maxX: math.max(1, maxX),
        maxY: maxY,
        played: [
          _bar(spots(played, (b) => b.totalBps), AppColors.faint),
          _bar(spots(played, (b) => b.matchedBps), AppColors.success),
          _bar(spots(played, (b) => b.unmatchedBps), AppColors.destructive,
              fill: true),
        ],
        future: [
          dimmed(spots(future, (b) => b.totalBps), AppColors.faint),
          dimmed(spots(future, (b) => b.matchedBps), AppColors.success),
          dimmed(
              spots(future, (b) => b.unmatchedBps), AppColors.destructive),
        ],
        bottomLabel: (value) => '${value.toStringAsFixed(0)}s',
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
  required String Function(double) bottomLabel,
}) {
  final step = _niceStep(maxY / 3);
  final interval = maxY / (maxY / step).round().clamp(2, 6);
  return LineChartData(
    minX: minX,
    maxX: maxX,
    minY: 0,
    maxY: maxY,
    gridData: FlGridData(
      show: true,
      drawVerticalLine: true,
      verticalInterval: 15,
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
          interval: 15,
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
    lineTouchData: const LineTouchData(),
    lineBarsData: [...played, ...?future],
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

String _compactBytes(int bytes) {
  if (bytes < 1000) return '$bytes B';
  if (bytes < 1000000) return '${(bytes / 1000).toStringAsFixed(1)} kB';
  return '${(bytes / 1000000).toStringAsFixed(1)} MB';
}

class _StatsRow extends StatelessWidget {
  final List<(String, String)> cards;

  const _StatsRow({required this.cards});

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 12,
      runSpacing: 12,
      children: [
        for (final (label, value) in cards)
          SizedBox(
            width: 160,
            child: AppCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(label, style: AppText.microLabel.copyWith(fontSize: 9)),
                  const SizedBox(height: 4),
                  Text(value, style: AppText.monoValue.copyWith(fontSize: 14)),
                ],
              ),
            ),
          ),
      ],
    );
  }
}
