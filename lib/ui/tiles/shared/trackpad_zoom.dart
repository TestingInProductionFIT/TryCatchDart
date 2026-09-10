import 'dart:math' as math;

/// Continuous zoom factor shared by the mouse-wheel and trackpad paths.
///
/// One wheel notch (Δ = ±120) maps to exactly ×1.1 — the long-standing wheel
/// step — while trackpad deltas stream in small increments and compound
/// smoothly through the same curve. Pass a wheel
/// `PointerScrollEvent.scrollDelta.dy` or a trackpad
/// `PointerPanZoomUpdateEvent.panDelta.dy`: up/negative zooms in, matching
/// the wheel sense (scroll up = zoom in).
double scrollZoomFactor(double dy) => math.pow(1.1, -dy / 120.0).toDouble();
