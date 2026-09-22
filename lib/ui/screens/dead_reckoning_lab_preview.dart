import 'dart:math' as math;
import 'dart:ui' show PointMode;

import 'package:flutter/material.dart';

import '../../theme/app_colors.dart';
import '../tiles/shared/flight_3d_common.dart' show niceCeil;

/// One outage's preview tracks, east/north/up metres from the outage start.
class OutagePreview {
  final String label;
  final List<Enu> before;
  final List<Enu> estimate;
  final List<Enu> real;

  /// Predicted regime per [estimate] point (`climb`/`descent`/…), used to
  /// mark where the guess expects the descent to settle.
  final List<String?> estimateRegimes;

  const OutagePreview({
    required this.label,
    required this.before,
    required this.estimate,
    required this.real,
    this.estimateRegimes = const [],
  });
}

/// East/north/up metres.
typedef Enu = ({double e, double n, double u});

/// What each preview track means: flown input, new guess, and what
/// really happened.
class PreviewLegend extends StatelessWidget {
  const PreviewLegend({super.key});

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 14,
      runSpacing: 4,
      children: [
        _LegendItem(label: 'Flown', color: previewFlownColor),
        _LegendItem(label: 'New guess', color: previewEstimateColor),
        _LegendItem(label: 'Actual', color: AppColors.pink),
      ],
    );
  }
}

class _LegendItem extends StatelessWidget {
  final String label;
  final Color color;

  const _LegendItem({
    required this.label,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        CustomPaint(
          size: const Size(22, 8),
          painter: _SwatchPainter(color: color),
        ),
        const SizedBox(width: 5),
        Text(
          label,
          style:
              TextStyle(fontSize: 11.5, color: AppColors.mutedForeground),
        ),
      ],
    );
  }
}

class _SwatchPainter extends CustomPainter {
  final Color color;

  _SwatchPainter({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 2.2
      ..strokeCap = StrokeCap.round;
    const y = 4.0;
    canvas.drawLine(const Offset(1, y), Offset(size.width - 1, y), paint);
  }

  @override
  bool shouldRepaint(covariant _SwatchPainter old) =>
      old.color != color;
}

/// Outage stepper: chevrons plus tappable dots. Swiping is deliberately
/// not a gesture here — horizontal drags rotate the 3D preview above,
/// so paging lives on buttons.
class OutageCarousel extends StatelessWidget {
  final int count;
  final int index;
  final String label;
  final VoidCallback? onPrevious;
  final VoidCallback? onNext;
  final ValueChanged<int> onSelect;

  const OutageCarousel({
    super.key,
    required this.count,
    required this.index,
    required this.label,
    required this.onPrevious,
    required this.onNext,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        IconButton(
          icon: const Icon(Icons.chevron_left, size: 22),
          tooltip: 'Previous outage',
          onPressed: onPrevious,
        ),
        Expanded(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'Outage ${index + 1} of $count · $label',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: AppText.mono.copyWith(
                  fontSize: 11,
                  color: AppColors.mutedForeground,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
              const SizedBox(height: 5),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  for (var i = 0; i < count; i++)
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 3),
                      child: InkWell(
                        onTap: i == index ? null : () => onSelect(i),
                        borderRadius: BorderRadius.circular(6),
                        child: Container(
                          width: i == index ? 16 : 8,
                          height: 8,
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(4),
                            color: i == index
                                ? AppColors.foreground
                                : Colors.transparent,
                            border: i == index
                                ? null
                                : Border.all(color: AppColors.faint),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ],
          ),
        ),
        IconButton(
          icon: const Icon(Icons.chevron_right, size: 22),
          tooltip: 'Next outage',
          onPressed: onNext,
        ),
      ],
    );
  }
}


// ── Rotatable 3D outage preview ──────────────────────────────────────────────

/// Drag-to-rotate 3D view of one outage: flown input solid blue, new
/// guess solid purple, actual continuation solid pink (outage window
/// only).
class OutagePreview3d extends StatefulWidget {
  final OutagePreview preview;

  const OutagePreview3d({super.key, required this.preview});

  @override
  State<OutagePreview3d> createState() => _OutagePreview3dState();
}

/// Preview track colors, shared by the legend and the 3D painter.
final previewFlownColor = AppColors.seriesGpsTrack;
final previewEstimateColor = AppColors.seriesDeadReckoning;

class _OutagePreview3dState extends State<OutagePreview3d> {
  static const kInitialYaw = -0.6;
  static const kInitialPitch = 0.5;

  double _yaw = kInitialYaw;
  double _pitch = kInitialPitch;

  void _resetView() {
    _yaw = kInitialYaw;
    _pitch = kInitialPitch;
  }

  @override
  void didUpdateWidget(covariant OutagePreview3d old) {
    super.didUpdateWidget(old);
    if (old.preview != widget.preview) _resetView();
  }

  @override
  Widget build(BuildContext context) {
    return ExcludeSemantics(
      child: Container(
        height: 230,
        decoration: BoxDecoration(
          color: AppColors.muted.withValues(alpha: 0.2),
          borderRadius: BorderRadius.circular(AppDimens.radiusSmall),
          border: Border.all(color: AppColors.border),
        ),
        clipBehavior: Clip.hardEdge,
        child: GestureDetector(
          onPanUpdate: (details) => setState(() {
            _yaw += details.delta.dx * 0.01;
            _pitch =
                (_pitch + details.delta.dy * 0.01).clamp(0.05, 1.4);
          }),
          onDoubleTap: () => setState(_resetView),
          child: CustomPaint(
            painter: _OutagePreviewPainter(
              preview: widget.preview,
              yaw: _yaw,
              pitch: _pitch,
              beforeColor: previewFlownColor,
              estimateColor: previewEstimateColor,
              actualColor: AppColors.pink,
            ),
          ),
        ),
      ),
    );
  }
}

class _OutagePreviewPainter extends CustomPainter {
  final OutagePreview preview;
  final double yaw;
  final double pitch;
  final Color beforeColor;
  final Color estimateColor;
  final Color actualColor;

  _OutagePreviewPainter({
    required this.preview,
    required this.yaw,
    required this.pitch,
    required this.beforeColor,
    required this.estimateColor,
    required this.actualColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final all = <Enu>[
      ...preview.before,
      ...preview.estimate,
      ...preview.real,
    ];
    if (all.isEmpty) return;
    var minE = double.infinity;
    var maxE = double.negativeInfinity;
    var minN = double.infinity;
    var maxN = double.negativeInfinity;
    var minU = double.infinity;
    var maxU = double.negativeInfinity;
    for (final p in all) {
      minE = math.min(minE, p.e);
      maxE = math.max(maxE, p.e);
      minN = math.min(minN, p.n);
      maxN = math.max(maxN, p.n);
      minU = math.min(minU, p.u);
      maxU = math.max(maxU, p.u);
    }
    final cE = (minE + maxE) / 2;
    final cN = (minN + maxN) / 2;
    final cU = (minU + maxU) / 2;
    final span = math.max(
      1.0,
      math.max(maxE - minE, math.max(maxN - minN, maxU - minU)),
    );
    final scale =
        math.min(size.width, size.height) / span * 0.8;

    final cosY = math.cos(yaw);
    final sinY = math.sin(yaw);
    final cosP = math.cos(pitch);
    final sinP = math.sin(pitch);
    Offset project(Enu p) {
      final x = p.e - cE;
      final z = p.n - cN;
      final y = p.u - cU;
      // Yaw about the vertical, then pitch the depth away.
      final rx = x * cosY - z * sinY;
      final depth = x * sinY + z * cosY;
      final ry = y * cosP - depth * sinP;
      return Offset(
        size.width / 2 + rx * scale,
        size.height / 2 - ry * scale,
      );
    }

    Paint stroke(Color color, double width, [double alpha = 1]) => Paint()
      ..color = color.withValues(alpha: alpha)
      ..strokeWidth = width
      ..style = PaintingStyle.stroke
      ..strokeJoin = StrokeJoin.round
      ..strokeCap = StrokeCap.round;

    void groundLabel(Enu world, String text, Color color) {
      final pos = project(world);
      final tp = TextPainter(
        text: TextSpan(
          text: text,
          style: AppText.microLabel.copyWith(
            fontSize: 10,
            letterSpacing: 1,
            color: color,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, pos + const Offset(-4, -8));
    }

    // Ground fill + 1-2-5 grid + N/E labels, in the flight 3D voice.
    final half = niceCeil(math.max(
        20.0, math.max((maxE - minE) * 0.75, (maxN - minN) * 0.75)));
    final step = niceCeil(half / 8);
    final gridN = (half / step).ceil();
    // Project each ground corner once: mixing one corner's x with
    // another's y (as the old moveTo/lineTo chain did) warps the fill
    // whenever yaw/pitch separates the two corners on screen.
    final groundCorners = [
      project((e: cE - half, n: cN - half, u: minU)),
      project((e: cE + half, n: cN - half, u: minU)),
      project((e: cE + half, n: cN + half, u: minU)),
      project((e: cE - half, n: cN + half, u: minU)),
    ];
    canvas.drawPath(
      Path()..addPolygon(groundCorners, true),
      Paint()..color = AppColors.muted.withValues(alpha: 0.65),
    );
    final gridLine = Paint()
      ..color = AppColors.border
      ..strokeWidth = 1;
    final axisLine = Paint()
      ..color = AppColors.strongBorder
      ..strokeWidth = 1.4;
    for (var k = -gridN; k <= gridN; k++) {
      final off = k * step;
      final paint = k == 0 ? axisLine : gridLine;
      canvas.drawLine(
        project((e: cE + off, n: cN - half, u: minU)),
        project((e: cE + off, n: cN + half, u: minU)),
        paint,
      );
      canvas.drawLine(
        project((e: cE - half, n: cN + off, u: minU)),
        project((e: cE + half, n: cN + off, u: minU)),
        paint,
      );
    }
    groundLabel(
        (e: cE + half + step * 0.3, n: cN, u: minU), 'E', AppColors.warning);
    groundLabel(
        (e: cE, n: cN + half + step * 0.3, u: minU), 'N', AppColors.info);

    final realPts = [for (final p in preview.real) project(p)];
    final beforePts = [for (final p in preview.before) project(p)];
    final estimatePts = [for (final p in preview.estimate) project(p)];

    // Flown input solid blue; new guess solid purple; actual
    // continuation solid pink. No drop lines — the tracks alone tell
    // the story.
    if (beforePts.length > 1) {
      canvas.drawPoints(
          PointMode.polygon, beforePts, stroke(beforeColor, 2.2, 0.85));
    }
    if (realPts.length > 1) {
      canvas.drawPoints(
          PointMode.polygon, realPts, stroke(actualColor, 2.2));
    }
    if (estimatePts.length > 1) {
      canvas.drawPoints(
          PointMode.polygon, estimatePts, stroke(estimateColor, 2.2));
    }
    // Ring where the guess settles into descent (predicted apogee/chute
    // transition inside the outage). Only when the track actually changes
    // regime mid-outage — always-descending outages need no marker.
    final regimes = preview.estimateRegimes;
    var settle = -1;
    for (var i = 1; i < regimes.length && i < estimatePts.length; i++) {
      if (regimes[i] == 'descent' && regimes[i - 1] != 'descent') {
        settle = i;
        break;
      }
    }
    if (settle >= 0) {
      canvas.drawCircle(
        estimatePts[settle],
        5,
        Paint()
          ..color = estimateColor
          ..style = PaintingStyle.fill,
      );
      canvas.drawCircle(
        estimatePts[settle],
        5,
        Paint()
          ..color = AppColors.card
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.6,
      );
    }
    // Cutout marker: where the fixes stop and the guessing starts.
    if (preview.before.isNotEmpty) {
      canvas.drawCircle(
        project(preview.before.last),
        4,
        Paint()..color = AppColors.pinkDeep,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _OutagePreviewPainter old) =>
      old.preview != preview ||
      old.yaw != yaw ||
      old.pitch != pitch;
}
