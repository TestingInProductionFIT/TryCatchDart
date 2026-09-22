import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trycatch/theme/app_colors.dart';
import 'package:trycatch/ui/tiles/shared/time_series_chart.dart';

/// Live: the single opaque bar per series answers touch; dimmed bars never
/// occur live, and ignoring them changes nothing. Replay: visual played +
/// dimmed-future bars sit out of touch and invisible per-series touch bars
/// answer instead — one match per series, so hovers can never twin at the
/// junction or stick across the playhead.
///
/// Role detection is alpha-based on purpose: LineChart runs every frame
/// through an animation tween, so the painter sees lerped *copies* and
/// object identity never matches in production.
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

  group('chartTouchData replay touch bars', () {
    // Replay layout: visual played + dimmed future (carrying the junction
    // duplicate at x=10) plus one invisible touch bar per series over the
    // unified samples. Only the touch bar may respond.
    late LineChartBarData played;
    late LineChartBarData future;
    late LineChartBarData touch;
    late List<(String, Color)> entries;

    LineChartBarData bar(List<FlSpot> spots, Color color) => LineChartBarData(
          spots: spots,
          color: color,
          barWidth: 1.6,
          isCurved: false,
          dotData: const FlDotData(show: false),
        );

    setUp(() {
      played = bar(
        const [FlSpot(10, 1.0)],
        AppColors.seriesAccel,
      );
      future = bar(
        const [FlSpot(10, 1.0), FlSpot(20, 2.0)],
        AppColors.seriesAccel.withValues(alpha: previewBarAlpha),
      );
      touch = bar(
        const [FlSpot(10, 1.0), FlSpot(20, 2.0)],
        AppColors.seriesAccel.withValues(alpha: 0),
      );
      entries = [
        ('Vertical', AppColors.seriesAccel),
        ('Vertical', AppColors.seriesAccel),
        ('Vertical', AppColors.seriesAccel),
      ];
    });

    LineTouchData touchData() => chartTouchData(
          entries: entries,
          unit: 'G',
          formatX: (x) => '${x.toStringAsFixed(0)}s',
          formatY: (v) => v.toStringAsFixed(2),
          touchBarsOnly: true,
        );

    test('visual bars draw no crosshair, touch bar does', () {
      final t = touchData();
      expect(t.getTouchedSpotIndicator(played, [0]).single, isNull);
      expect(t.getTouchedSpotIndicator(future, [0]).single, isNull);
      expect(t.getTouchedSpotIndicator(future, [1]).single, isNull);
      expect(t.getTouchedSpotIndicator(touch, [0]).single, isNotNull);
      expect(t.getTouchedSpotIndicator(touch, [1]).single, isNotNull);
    });

    test('touch dot re-opacifies the series color', () {
      final t = touchData();
      final head = t.getTouchedSpotIndicator(touch, [1]).single!;
      // getDotPainter closes over the bar color: invoke it and read back
      // the painter's color. The touch bar is transparent series color, so
      // the head must come back fully opaque in the series hue.
      final painter = head.touchedSpotDotData.getDotPainter(
        touch.spots[1],
        0,
        touch,
        1,
      ) as FlDotCirclePainter;
      expect(painter.color, AppColors.seriesAccel);
      expect(painter.color.a, 1.0);
    });

    test('tooltip answers only the touch bar, once per series', () {
      final t = touchData();
      final items = t.touchTooltipData.getTooltipItems([
        LineBarSpot(played, 0, played.spots.first),
        LineBarSpot(future, 1, future.spots.first),
        LineBarSpot(future, 1, future.spots[1]),
        LineBarSpot(touch, 2, touch.spots[1]),
      ]);
      // Same length (fl_chart requires 1:1); visual rows are null, so the
      // junction can never twin and played rows never stick.
      expect(items, hasLength(4));
      expect(items[0], isNull);
      expect(items[1], isNull);
      expect(items[2], isNull);
      expect(items[3]?.text, contains('20s'));
      expect(items[3]?.text, contains('VERTICAL'));
      expect(items[3]?.text, contains('2.00'));
    });

    test('multi-series rows align into columns', () {
      final t = chartTouchData(
        entries: [
          ('A', AppColors.seriesAccel),
          ('Longer', AppColors.seriesBattery),
        ],
        unit: 'G',
        formatX: (x) => '${x.toStringAsFixed(0)}s',
        formatY: (v) => v.toStringAsFixed(2),
      );
      final a = bar(
        const [FlSpot(10, 1.0)],
        AppColors.seriesAccel,
      );
      final b = bar(
        const [FlSpot(10, 22.5)],
        AppColors.seriesBattery,
      );
      final items = t.touchTooltipData.getTooltipItems([
        LineBarSpot(a, 0, a.spots.first),
        LineBarSpot(b, 1, b.spots.first),
      ]);
      final lines = [
        for (final item in items) item!.text.split('\n').last,
      ];
      // Same mono width ⇒ labels left-aligned, values right-aligned.
      expect(lines[0].length, lines[1].length);
      expect(lines[0], contains('1.00'));
      expect(lines[1], contains('22.50'));
    });
  });
}
