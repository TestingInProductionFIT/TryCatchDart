import 'package:flutter/material.dart';

import '../../core/flight_events.dart';
import '../../theme/app_colors.dart';

/// Presentation half of the data-driven flight events: icon + color per
/// event type, in one table shared by the replay timeline markers and the
/// events tile. (Matching state changes live on [FlightEventType] itself in
/// `core/flight_events.dart`, which stays Flutter-free.)
///
/// Colors are `Color Function()` tear-offs, not constants: [AppColors]
/// resolves the active palette at read time, so markers and log rows follow
/// dark-mode flips like everything else.
class FlightEventStyle {
  /// Marker/log glyph.
  final IconData icon;

  /// Reads the current palette color for the event.
  final Color Function() color;

  const FlightEventStyle({required this.icon, required this.color});
}

/// The single style table for flight events.
FlightEventStyle flightEventStyleOf(FlightEventType type) => switch (type) {
  FlightEventType.launch => FlightEventStyle(
    icon: Icons.rocket_launch,
    color: () => AppColors.warning,
  ),
  FlightEventType.apogee => FlightEventStyle(
    icon: Icons.arrow_upward,
    color: () => AppColors.pinkDeep,
  ),
  FlightEventType.parachute => FlightEventStyle(
    icon: Icons.paragliding,
    color: () => AppColors.info,
  ),
  FlightEventType.touchdown => FlightEventStyle(
    icon: Icons.flight_land,
    color: () => AppColors.success,
  ),
};

/// Marker dot for one flight event: type-colored circle with a card-colored
/// ring so it reads on the slider track and in log rows in both palettes.
///
/// Purely visual — dimming included. Callers own playhead subscriptions so
/// only this dot rebuilds while tooltips/buttons around it stay stable.
class FlightEventDot extends StatelessWidget {
  final FlightEventType type;

  /// Diameter in logical pixels.
  final double size;

  /// Dimmed while still ahead of the playhead.
  final bool dimmed;

  const FlightEventDot({
    super.key,
    required this.type,
    this.size = flightEventDotDiameterPx,
    this.dimmed = false,
  });

  @override
  Widget build(BuildContext context) {
    final base = flightEventStyleOf(type).color();
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: dimmed ? base.withValues(alpha: 0.35) : base,
        border: Border.all(color: AppColors.card, width: 2),
      ),
      child: Icon(
        flightEventStyleOf(type).icon,
        size: size * 0.55,
        color: AppColors.card,
      ),
    );
  }
}
