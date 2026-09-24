import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trycatch/ui/tiles/shared/slippy_math.dart';

/// Probe for the HANDOFF 2.4 claim that `Canvas.transform` with a
/// perspective matrix "silently paints nothing on Impeller/OpenGLES".
///
/// Paints a checker image through a single perspective homography
/// (image rect -> trapezoid screen quad, i.e. true perspective with
/// w != 1) via save/transform/drawImage, then measures painted pixels.
///
/// NOTE: `flutter test` runs on the software rasterizer, so a pass here
/// proves the Dart-side matrix plumbing, not Impeller. Kept as a
/// regression guard for the matrix math; see engine
/// `Canvas::transform -> TransformFullPerspective` for Impeller support.
void main() {
  Future<ui.Image> checker() async {
    const s = 256;
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);
    canvas.drawRect(
      ui.Rect.fromLTWH(0, 0, s.toDouble(), s.toDouble()),
      ui.Paint()..color = const ui.Color(0xFF000000),
    );
    var flip = false;
    for (var j = 0; j < 8; j++) {
      for (var i = 0; i < 8; i++) {
        flip = !flip;
        if (!flip) continue;
        canvas.drawRect(
          ui.Rect.fromLTWH(i * 32.0, j * 32.0, 32, 32),
          ui.Paint()..color = const ui.Color(0xFFFFFFFF),
        );
      }
    }
    final picture = recorder.endRecording();
    final image = await picture.toImage(s, s);
    picture.dispose();
    return image;
  }

  Future<Uint8List> render(
      WidgetTester tester, CustomPainter painter) async {
    final key = GlobalKey();
    await tester.pumpWidget(
      MaterialApp(
        home: RepaintBoundary(
          key: key,
          child: SizedBox(
            width: 800,
            height: 600,
            child: CustomPaint(painter: painter),
          ),
        ),
      ),
    );
    await tester.pump();
    final boundary =
        key.currentContext!.findRenderObject() as RenderRepaintBoundary;
    final image =
        (await tester.runAsync(() => boundary.toImage()))!;
    final data = (await tester.runAsync(
        () => image.toByteData(format: ui.ImageByteFormat.rawRgba)))!;
    final bytes = Uint8List.fromList(data.buffer.asUint8List());
    image.dispose();
    return bytes;
  }

  double whiteFraction(Uint8List px) {
    var white = 0;
    const total = 800 * 600;
    for (var i = 0; i < total; i++) {
      if (px[i * 4] > 128) white++;
    }
    return white / total;
  }

  testWidgets('perspective Canvas.transform paints (probe)', (tester) async {
    final image = await checker();
    try {
      // Image corners -> trapezoid (perspective, not affine).
      final h = solveHomography(
        const [
          (x: 0.0, y: 0.0),
          (x: 256.0, y: 0.0),
          (x: 256.0, y: 256.0),
          (x: 0.0, y: 256.0),
        ],
        const [
          (x: 200.0, y: 100.0),
          (x: 600.0, y: 100.0),
          (x: 700.0, y: 500.0),
          (x: 100.0, y: 500.0),
        ],
      )!;
      final painter = _TransformPainter(image, homographyMatrix(h));
      final px = await render(tester, painter);
      final frac = whiteFraction(px);
      debugPrint('perspective-transform white fraction: $frac');
      // Trapezoid area ~ 180k px of 480k; checker is ~half white.
      expect(frac, greaterThan(0.1));
    } finally {
      image.dispose();
    }
  });
}

class _TransformPainter extends CustomPainter {
  final ui.Image image;
  final List<double> matrix;
  _TransformPainter(this.image, this.matrix);

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(
        Offset.zero & size, Paint()..color = const Color(0xFF000000));
    canvas.save();
    canvas.transform(Float64List.fromList(matrix));
    canvas.drawImageRect(
      image,
      Rect.fromLTWH(
          0, 0, image.width.toDouble(), image.height.toDouble()),
      Rect.fromLTWH(
          0, 0, image.width.toDouble(), image.height.toDouble()),
      Paint()..filterQuality = FilterQuality.low,
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
