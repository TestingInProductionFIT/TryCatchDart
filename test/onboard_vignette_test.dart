import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trycatch/ui/tiles/shared/flight_3d_common.dart';

/// Locks the onboard camera vignette: over a flat white field the frame
/// centre must stay clean while the corners pick up the lens darkening.
void main() {
  Future<Uint8List> renderVignette(WidgetTester tester) async {
    final key = GlobalKey();
    await tester.pumpWidget(
      MaterialApp(
        home: RepaintBoundary(
          key: key,
          child: SizedBox(
            width: 800,
            height: 600,
            child: CustomPaint(painter: _VignetteProbe()),
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
    final bytes = data.buffer.asUint8List();
    image.dispose();
    return bytes;
  }

  int luminanceAt(Uint8List bytes, int x, int y) {
    final i = (y * 800 + x) * 4;
    return ((bytes[i] + bytes[i + 1] + bytes[i + 2]) / 3).round();
  }

  testWidgets('vignette keeps the centre clean and darkens the corners',
      (tester) async {
    final bytes = await renderVignette(tester);
    final center = luminanceAt(bytes, 400, 300);
    expect(center, greaterThan(245));
    // Deep inside the frame the glass stays clean — the darkening hugs
    // the periphery.
    expect(luminanceAt(bytes, 600, 300), greaterThan(245));
    expect(luminanceAt(bytes, 400, 150), greaterThan(245));
    for (final corner in [
      (10, 10),
      (789, 10),
      (10, 589),
      (789, 589),
    ]) {
      final v = luminanceAt(bytes, corner.$1, corner.$2);
      expect(v, lessThan(center - 30), reason: 'corner $corner');
      expect(v, lessThan(200), reason: 'corner $corner');
    }
  });
}

class _VignetteProbe extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(
      Offset.zero & size,
      Paint()..color = const Color(0xFFFFFFFF),
    );
    paintVignette(canvas, size);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
