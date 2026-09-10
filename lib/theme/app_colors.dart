import 'package:flutter/material.dart';
import 'package:serial/serial.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/prefs_keys.dart';

/// Concrete color palette: every color the app uses, in one place.
///
/// Two instances exist ([AppPalette.light] = "Precision Light",
/// [AppPalette.dark]). Tiles never touch the palette directly — they read
/// [AppColors], whose getters resolve through the global [AppThemeMode], so
/// flipping the toggle re-themes the whole app without touching call sites.
class AppPalette {
  final Color background;
  final Color card;
  final Color foreground;
  final Color muted;
  final Color mutedForeground;
  final Color faint;
  final Color border;
  final Color strongBorder;

  final Color pink;
  final Color pinkDeep;
  final Color pinkSoft;
  final Color primary;
  final Color primaryForeground;

  final Color destructive;
  final Color success;
  final Color warning;
  final Color info;
  final Color successSoft;
  final Color warningSoft;
  final Color dangerSoft;

  final Color seriesAltitude;
  final Color seriesVelocity;
  final Color seriesVelocityVertical;
  final Color seriesAccel;
  final Color seriesBattery;
  final Color seriesGpsTrack;
  final Color seriesDeadReckoning;

  final Color fsmLanded;
  final Color fsmParachute;

  const AppPalette({
    required this.background,
    required this.card,
    required this.foreground,
    required this.muted,
    required this.mutedForeground,
    required this.faint,
    required this.border,
    required this.strongBorder,
    required this.pink,
    required this.pinkDeep,
    required this.pinkSoft,
    required this.primary,
    required this.primaryForeground,
    required this.destructive,
    required this.success,
    required this.warning,
    required this.info,
    required this.successSoft,
    required this.warningSoft,
    required this.dangerSoft,
    required this.seriesAltitude,
    required this.seriesVelocity,
    required this.seriesVelocityVertical,
    required this.seriesAccel,
    required this.seriesBattery,
    required this.seriesGpsTrack,
    required this.seriesDeadReckoning,
    required this.fsmLanded,
    required this.fsmParachute,
  });

  static const light = AppPalette(
    background: Color(0xFFF5F4F6),
    card: Color(0xFFFFFFFF),
    foreground: Color(0xFF1B1820),
    muted: Color(0xFFF7F6F8),
    mutedForeground: Color(0xFF6C6674),
    faint: Color(0xFFA29CA9),
    border: Color(0xFFE6E3E9),
    strongBorder: Color(0xFFCFCAD4),
    pink: Color(0xFFFF00A1),
    pinkDeep: Color(0xFFD6008A),
    pinkSoft: Color(0xFFFFE9F5),
    primary: Color(0xFFFF00A1),
    primaryForeground: Color(0xFFFFFFFF),
    destructive: Color(0xFFD42A2A),
    success: Color(0xFF0E8A63),
    warning: Color(0xFFC77414),
    info: Color(0xFF2260DB),
    successSoft: Color(0xFFEBF7F2),
    warningSoft: Color(0xFFFCF3E4),
    dangerSoft: Color(0xFFFBEDED),
    seriesAltitude: Color(0xFFFF00A1),
    seriesVelocity: Color(0xFF2260DB),
    seriesVelocityVertical: Color(0xFF0E8A63),
    seriesAccel: Color(0xFFC77414),
    seriesBattery: Color(0xFF7C3AED),
    seriesGpsTrack: Color(0xFF2260DB),
    seriesDeadReckoning: Color(0xFF7C3AED),
    fsmLanded: Color(0xFF4A4652),
    fsmParachute: Color(0xFF0D9488),
  );

  static const dark = AppPalette(
    background: Color(0xFF131216),
    card: Color(0xFF1E1B22),
    foreground: Color(0xFFF1EEF4),
    muted: Color(0xFF27232D),
    mutedForeground: Color(0xFFA9A3B2),
    faint: Color(0xFF6F6979),
    border: Color(0xFF36313E),
    strongBorder: Color(0xFF4E4757),
    pink: Color(0xFFFF00A1),
    pinkDeep: Color(0xFFFF4DAD),
    pinkSoft: Color(0xFF3D1F36),
    primary: Color(0xFFFF00A1),
    primaryForeground: Color(0xFFFFFFFF),
    destructive: Color(0xFFEF6B6B),
    success: Color(0xFF34C98E),
    warning: Color(0xFFE09A3C),
    info: Color(0xFF6B94F5),
    successSoft: Color(0xFF123B2F),
    warningSoft: Color(0xFF44330F),
    dangerSoft: Color(0xFF471B1B),
    seriesAltitude: Color(0xFFFF00A1),
    seriesVelocity: Color(0xFF6B94F5),
    seriesVelocityVertical: Color(0xFF34C98E),
    seriesAccel: Color(0xFFE09A3C),
    seriesBattery: Color(0xFFA78BFA),
    seriesGpsTrack: Color(0xFF6B94F5),
    seriesDeadReckoning: Color(0xFFA78BFA),
    fsmLanded: Color(0xFF8E8898),
    fsmParachute: Color(0xFF2DD4BF),
  );
}

/// Global light/dark switch, persisted across launches.
///
/// A [ValueNotifier] (not Riverpod — theming sits below the provider scope):
/// the app root listens and rebuilds [MaterialApp] on toggle, and every
/// [AppColors] getter resolves the active palette, so all tiles follow.
class AppThemeMode extends ValueNotifier<bool> {
  static const String _prefsKey = PrefsKeys.darkMode;

  static final AppThemeMode instance = AppThemeMode._(false);

  AppThemeMode._(super.value);

  bool get isDark => value;

  Future<void> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final dark = prefs.getBool(_prefsKey);
      if (dark != null) value = dark;
    } catch (_) {
      // Fall back to light.
    }
  }

  Future<void> setDark(bool dark) async {
    value = dark;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_prefsKey, dark);
    } catch (_) {
      // Non-fatal; the in-memory choice still applies.
    }
  }
}

/// App-wide color access. NEVER cache these in a `final`/`const` — always
/// read them inside `build()` (or theme builders) so a dark-mode toggle
/// repaints correctly.
abstract final class AppColors {
  static AppPalette get _p =>
      AppThemeMode.instance.value ? AppPalette.dark : AppPalette.light;

  // ── Surfaces & text ─────────────────────────────────────────────────────────
  static Color get background => _p.background;
  static Color get card => _p.card;
  static Color get foreground => _p.foreground;
  static Color get muted => _p.muted;
  static Color get mutedForeground => _p.mutedForeground;
  static Color get faint => _p.faint;
  static Color get border => _p.border;
  static Color get strongBorder => _p.strongBorder;

  // ── Team accent ─────────────────────────────────────────────────────────────
  /// Neon team pink — graphics, live indicators, filled accents.
  static Color get pink => _p.pink;

  /// Pink readable as text / small strokes (deep on light, lifted on dark).
  static Color get pinkDeep => _p.pinkDeep;

  /// Soft pink wash behind pink labels and chips.
  static Color get pinkSoft => _p.pinkSoft;

  /// Primary interactive accent.
  static Color get primary => _p.primary;
  static Color get primaryForeground => _p.primaryForeground;

  // ── Status (kept non-pink so pink stays special) ───────────────────────────
  static Color get destructive => _p.destructive;
  static Color get success => _p.success;
  static Color get warning => _p.warning;
  static Color get info => _p.info;

  /// Soft washes behind the status pills.
  static Color get successSoft => _p.successSoft;
  static Color get warningSoft => _p.warningSoft;
  static Color get dangerSoft => _p.dangerSoft;

  // ── Chart series ────────────────────────────────────────────────────────────
  /// Barometric altitude — the team colour, the headline series.
  static Color get seriesAltitude => _p.seriesAltitude;
  static Color get seriesVelocity => _p.seriesVelocity;
  static Color get seriesVelocityVertical => _p.seriesVelocityVertical;
  static Color get seriesAccel => _p.seriesAccel;
  static Color get seriesBattery => _p.seriesBattery;
  static Color get seriesGpsTrack => _p.seriesGpsTrack;
  static Color get seriesDeadReckoning => _p.seriesDeadReckoning;

  /// Semantic color per rocket FSM state.
  static Color fsmColor(FsmState state) => switch (state) {
        FsmState.idle => mutedForeground,
        FsmState.armed => warning,
        FsmState.ascent => destructive,
        FsmState.apogee => seriesDeadReckoning, // violet
        FsmState.parachute => _p.fsmParachute,
        FsmState.landed => _p.fsmLanded,
        // Bench states: unlocked (open airframe) amber, locked blue.
        FsmState.debugUnlocked => warning,
        FsmState.debugLocked => info,
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
  /// A getter (not final): the color follows the active palette.
  static TextStyle get microLabel => TextStyle(
        fontFamily: monoFamily,
        fontFamilyFallback: monoFallback,
        fontSize: 9.5,
        fontWeight: FontWeight.w700,
        letterSpacing: 1.4,
        color: AppColors.mutedForeground,
      );

  /// Compact monospace value (top-bar cells, readouts). Getter for the
  /// same reason.
  static TextStyle get monoValue => TextStyle(
        fontFamily: monoFamily,
        fontFamilyFallback: monoFallback,
        fontSize: 12.5,
        fontWeight: FontWeight.w700,
        color: AppColors.foreground,
        fontFeatures: [FontFeature.tabularFigures()],
      );
}
