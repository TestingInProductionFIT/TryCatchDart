import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

/// Does drawVertices+modulate respect per-vertex alpha?
void main() {
  Future<ui.Image> whiteImage() async {
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);
    canvas.drawRect(
      ui.Rect.fromLTWH(0, 0, 64, 64),
      ui.Paint()..color = const ui.Color(0xFFFFFFFF),
    );
    final picture = recorder.endRecording();
    final image = await picture.toImage(64, 64);
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

  (double r, double g, double b) mean(Uint8List px) {
    var r = 0, g = 0, b = 0;
    const total = 800 * 600;
    for (var i = 0; i < total; i++) {
      r += px[i * 4];
      g += px[i * 4 + 1];
      b += px[i * 4 + 2];
    }
    return (r / total, g / total, b / total);
  }

  testWidgets('vertex alpha fades under modulate', (tester) async {
    final image = await whiteImage();
    try {
      // Red background, fullscreen white-textured triangle.
      Future<(double, double, double)> run(ui.Color c) =>
          render(tester, _AlphaPainter(image, c)).then(mean);
      final opaque = await run(const ui.Color(0xFFFFFFFF));
      final half = await run(const ui.Color(0x80FFFFFF));
      final clear = await run(const ui.Color(0x00FFFFFF));
      debugPrint('opaque=$opaque half=$half clear=$clear');
      // Opaque white over red -> white.
      expect(opaque.$1, greaterThan(200));
      // Fully transparent -> red background shows through.
      expect(clear.$1, greaterThan(150));
      expect(clear.$3, lessThan(100));
      // Half -> pinkish middle.
      expect(half.$1, greaterThan(150));
      expect(half.$3, greaterThan(60));
      expect(half.$3, lessThan(200));
    } finally {
      image.dispose();
    }
  });
}

class _AlphaPainter extends CustomPainter {
  final ui.Image image;
  final ui.Color color;
  _AlphaPainter(this.image, this.color);

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(
        Offset.zero & size, Paint()..color = const Color(0xFFFF0000));
    final paint = Paint()
      ..shader = ui.ImageShader(
        image,
        ui.TileMode.clamp,
        ui.TileMode.clamp,
        Matrix4.identity().storage,
      );
    canvas.drawVertices(
      ui.Vertices(
        ui.VertexMode.triangles,
        const [
          Offset(0, 0),
          Offset(800, 0),
          Offset(0, 600),
          Offset(800, 0),
          Offset(800, 600),
          Offset(0, 600),
        ],
        textureCoordinates: const [
          Offset(0, 0),
          Offset(64, 0),
          Offset(0, 64),
          Offset(64, 0),
          Offset(64, 64),
          Offset(0, 64),
        ],
        colors: [color, color, color, color, color, color],
        indices: const [0, 1, 2, 3, 4, 5],
      ),
      ui.BlendMode.modulate,
      paint,
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
