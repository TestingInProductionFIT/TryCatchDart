import 'package:flutter/material.dart';
import 'package:serial/serial.dart';

/// "Precision Light" design language (2026-09 redesign).
///
/// Light engineering aesthetic: soft white cards on a cool grey desk,
/// hairline borders, monospace micro-labels for anything technical, and the
/// team pink (#FF00A1) reserved for brand moments, live indicators and
/// interactivity. Raw neon pink is illegible as text on white, so text-safe
/// accents use [pinkDeep]. Status semantics stay green/amber/red so pink
/// stays special.
abstract final class AppColors {
  // ── Surfaces & text ─────────────────────────────────────────────────────────
  static const Color background = Color(0xFFF5F4F6); // desk
  static const Color card = Color(0xFFFFFFFF);
  static const Color foreground = Color(0xFF1B1820); // ink
  static const Color muted = Color(0xFFF7F6F8); // sub-header surface
  static const Color mutedForeground = Color(0xFF6C6674);
  static const Color faint = Color(0xFFA29CA9);
  static const Color border = Color(0xFFE6E3E9);
  static const Color strongBorder = Color(0xFFCFCAD4);

  // ── Team accent ─────────────────────────────────────────────────────────────
  /// Neon team pink — graphics, live indicators, filled accents.
  static const Color pink = Color(0xFFFF00A1);

  /// Deepened pink readable as text / small strokes on white.
  static const Color pinkDeep = Color(0xFFD6008A);

  /// Soft pink wash behind pink labels and chips.
  static const Color pinkSoft = Color(0xFFFFE9F5);

  /// Primary interactive accent. Pink across the app: active toggles, drag
  /// handles, selection, primary buttons.
  static const Color primary = pink;
  static const Color primaryForeground = Color(0xFFFFFFFF);

  // ── Status (kept non-pink so pink stays special) ───────────────────────────
  static const Color destructive = Color(0xFFD42A2A);
  static const Color success = Color(0xFF0E8A63);
  static const Color warning = Color(0xFFC77414);
  static const Color info = Color(0xFF2260DB);

  /// Soft washes behind the status pills.
  static const Color successSoft = Color(0xFFEBF7F2);
  static const Color warningSoft = Color(0xFFFCF3E4);
  static const Color dangerSoft = Color(0xFFFBEDED);

  // ── Chart series ────────────────────────────────────────────────────────────
  /// Barometric altitude — the team colour, the headline series.
  static const Color seriesAltitude = pink;
  static const Color seriesVelocity = info; // horizontal speed
  static const Color seriesVelocityVertical = success;
  static const Color seriesAccel = warning;
  static const Color seriesBattery = Color(0xFF7C3AED); // violet
  static const Color seriesGpsTrack = info;
  static const Color seriesDeadReckoning = Color(0xFF7C3AED); // violet

  /// Semantic color per rocket FSM state.
  static Color fsmColor(FsmState state) => switch (state) {
        FsmState.idle => mutedForeground,
        FsmState.armed => warning,
        FsmState.boost => destructive,
        FsmState.coast => info,
        FsmState.apogee => Color(0xFF7C3AED), // violet
        FsmState.drogue => Color(0xFF0D9488), // teal
        FsmState.main => success,
        FsmState.landed => Color(0xFF4A4652),
        FsmState.fault => Color(0xFFB91C1C),
        FsmState.unknown => faint,
      };
}

/// Shared layout metrics so cards, grid and chrome stay visually consistent.
abstract final class AppDimens {
  /// Card / panel corner radius.
  static const double radius = 12;
  static const double radiusSmall = 8;
  static const double border = 1;

  static const double pagePadding = 16;
  static const double cardPadding = 13;
  static const double gap = 12;

  /// Padding around the workspace grid — mirrors [GridLayout.outerPadding].
  static const double outerPadding = 12;

  /// Height of the always-visible segmented top app bar.
  static const double topBarHeight = 52;

  /// Height of the workspace tab strip under the top bar.
  static const double workspaceTabsHeight = 44;
}

/// Typography tokens for the "technical voice": monospace micro-labels for
/// anything machine-ish (axis units, group labels, pills, readouts), the
/// default Segoe stack for prose.
abstract final class AppText {
  static const String monoFamily = 'Consolas';
  static const List<String> monoFallback = ['Courier New', 'monospace'];

  static const TextStyle mono = TextStyle(
    fontFamily: monoFamily,
    fontFamilyFallback: monoFallback,
  );

  /// Uppercase micro-label used on card header strips, top-bar cells and
  /// stats group labels. Color varies by context — pass via `copyWith`.
  static const TextStyle microLabel = TextStyle(
    fontFamily: monoFamily,
    fontFamilyFallback: monoFallback,
    fontSize: 9.5,
    fontWeight: FontWeight.w700,
    letterSpacing: 1.4,
    color: AppColors.mutedForeground,
  );

  /// Compact monospace value (top-bar cells, readouts).
  static const TextStyle monoValue = TextStyle(
    fontFamily: monoFamily,
    fontFamilyFallback: monoFallback,
    fontSize: 12.5,
    fontWeight: FontWeight.w700,
    color: AppColors.foreground,
    fontFeatures: [FontFeature.tabularFigures()],
  );
}
