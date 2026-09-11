import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trycatch/theme/app_colors.dart';
import 'package:trycatch/ui/tiles/shared/time_series_chart.dart';

/// Replay's dimmed future duplicates must stay out of touch: one crosshair
/// and one tooltip row per series (played values), never twin heads.
///
/// Detection is alpha-based on purpose: LineChart runs every frame through
/// an animation tween, so the painter sees lerped *copies* and object
/// identity never matches in production.
void main() {
  group('chartTouchData preview bars', () {
    late List<LineChartBarData> bars;
    late List<(String, Color)> entries;

    setUp(() {
      LineChartBarData bar(List<FlSpot> spots, Color color) =>
          LineChartBarData(
            spots: spots,
            color: color,
            barWidth: 1.6,
            isCurved: false,
            dotData: const FlDotData(show: false),
          );
      bars = [
        bar([const FlSpot(33, 1.03)], AppColors.seriesAccel),
        bar(
          [const FlSpot(33, 0.95)],
          AppColors.seriesAccel.withValues(alpha: previewBarAlpha),
        ),
      ];
      entries = [
        ('Vertical', AppColors.seriesAccel),
        ('Vertical', AppColors.seriesAccel),
      ];
    });

    LineTouchData touch() => chartTouchData(
          entries: entries,
          unit: 'G',
          formatX: (x) => '${x.toStringAsFixed(0)}s',
          formatY: (v) => v.toStringAsFixed(2),
        );

    test('faded clones draw no crosshair, opaque clones do', () {
      final t = touch();
      // Simulate the tween: the painter queries with copies, not the
      // original objects — identity must play no role.
      final fadedCopy = LineChartBarData(
        spots: bars[1].spots,
        color: bars[1].color,
        barWidth: 1.6,
        isCurved: false,
        dotData: const FlDotData(show: false),
      );
      final future = t.getTouchedSpotIndicator(fadedCopy, [0]);
      expect(future, hasLength(1));
      expect(future.single, isNull);

      final playedCopy = LineChartBarData(
        spots: bars[0].spots,
        color: bars[0].color,
        barWidth: 1.6,
        isCurved: false,
        dotData: const FlDotData(show: false),
      );
      final played = t.getTouchedSpotIndicator(playedCopy, [0]);
      expect(played, hasLength(1));
      expect(played.single, isNotNull);
    });

    test('tooltip skips preview rows without leaving blank lines', () {
      final t = touch();
      final items = t.touchTooltipData.getTooltipItems([
        LineBarSpot(bars[1], 1, bars[1].spots.first),
        LineBarSpot(bars[0], 0, bars[0].spots.first),
      ]);
      // Same length (fl_chart requires 1:1), preview row is null — skipped
      // with zero height, unlike an empty string which still takes a line.
      expect(items, hasLength(2));
      expect(items[0], isNull);
      expect(items[1]?.text, contains('33s'));
      expect(items[1]?.text, contains('VERTICAL'));
      expect(items[1]?.text, contains('1.03'));
    });

    test('fully opaque charts touch every bar as before', () {
      final solid = LineChartBarData(
        spots: const [FlSpot(33, 0.95)],
        color: AppColors.seriesAccel,
        barWidth: 1.6,
        isCurved: false,
        dotData: const FlDotData(show: false),
      );
      final t = touch();
      expect(t.getTouchedSpotIndicator(solid, [0]).single, isNotNull);
    });
  });
}
