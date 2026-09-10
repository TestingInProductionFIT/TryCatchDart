import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../state/replay_controller.dart';
import '../../core/geo.dart';
import '../../state/telemetry_store.dart';
import '../../theme/app_colors.dart';
import '../components/copy_button.dart';
import '../components/waiting_for_data.dart';

/// Position panel: one compact card with rows per fix — status label +
/// coordinates + altitude, each row carrying its own copy button (Google
/// Maps `lat, lon` format).
///
/// The copy buttons live in the label rows so they are always visible, even
/// in short tiles: the whole card scales down instead of dropping controls.
/// Dead reckoning is a live-only gap filler — during a replay only the GPS
/// rows show.
class StatsTile extends ConsumerWidget {
  const StatsTile({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(telemetryStoreProvider);
    final replaying = ref.watch(replayProvider).isActive;
    final latest = state.latest;
    final site = ref.watch(effectiveLaunchSiteProvider);

    if (latest == null) {
      return Center(child: WaitingForData());
    }

    final gpsDistance = site != null && latest.gpsHasFix
        ? haversineDistanceM(
            site.latitude, site.longitude, latest.latitude, latest.longitude)
        : null;

    // Same staleness rule as the store extrapolator and the 3D view: no
    // packets for over a second means the link (not just the fix) is down.
    final linkStale = !replaying &&
        DateTime.now().millisecondsSinceEpoch - latest.receivedAtMs >
            TelemetryStore.drStaleMs;

    var gpsLabel = latest.gpsHas3dFix
        ? 'GPS · 3D FIX'
        : latest.gpsHasFix
            ? 'GPS · FIX'
            : 'GPS · NO FIX';
    if (linkStale) gpsLabel += ' · STALE';

    final gpsCoords = latest.gpsHasFix
        ? formatLatLon(latest.latitude, latest.longitude)
        : '—';
    final gpsCopy = latest.gpsHasFix
        ? formatLatLonPlain(latest.latitude, latest.longitude)
        : null;
    final gpsSub = [
      formatAltitudeM(latest.gpsAltitude),
      if (gpsDistance != null)
        gpsDistance >= 1000
            ? '${(gpsDistance / 1000).toStringAsFixed(2)} km from site'
            : '${gpsDistance.toStringAsFixed(0)} m from site',
    ].join(' · ');

    String? drCoords;
    String? drCopy;
    String? drSub;
    String? drLabel;
    if (!replaying) {
      final dr = state.deadReckoning;
      // The extrapolator integrates the last velocity blindly, so after a
      // landing (or a long gap) it can sink below the ground — clamp the
      // readout at the site elevation. The 3D views clamp the same way via
      // their ground plane (world Y never goes negative).
      final drAlt = dr == null
          ? null
          : site == null
              ? dr.altitude
              : dr.altitude < site.altitudeMsl
                  ? site.altitudeMsl
                  : dr.altitude;
      drCoords = dr == null ? '—' : formatLatLon(dr.latitude, dr.longitude);
      drCopy = dr == null ? null : formatLatLonPlain(dr.latitude, dr.longitude);
      drSub = formatAltitudeM(drAlt);
      drLabel =
          linkStale ? 'DR · EXTRAPOLATING' : 'DEAD RECKONING';
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final content = Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _FixRow(
              label: gpsLabel,
              coords: gpsCoords,
              sub: gpsSub,
              copyText: gpsCopy,
            ),
            if (drCoords != null) ...[
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child:
                    Divider(height: 1, thickness: 1, color: AppColors.border),
              ),
              _FixRow(
                label: drLabel!,
                coords: drCoords,
                sub: drSub!,
                copyText: drCopy,
              ),
            ],
          ],
        );
        if (!constraints.maxHeight.isFinite) return content;
        return FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: constraints.maxWidth),
            child: content,
          ),
        );
      },
    );
  }
}

/// One fix block: micro label + copy button on top, coordinates below,
/// altitude line at the bottom.
class _FixRow extends StatelessWidget {
  final String label;
  final String coords;
  final String sub;

  /// When non-null, an icon copy button copies this (Google Maps format).
  final String? copyText;

  const _FixRow({
    required this.label,
    required this.coords,
    required this.sub,
    this.copyText,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                label.toUpperCase(),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppText.microLabel
                    .copyWith(fontSize: 9, letterSpacing: 1.2),
              ),
            ),
            if (copyText != null) CopyButton(text: copyText!, iconOnly: true),
          ],
        ),
        const SizedBox(height: 2),
        // Display-only live readout — excluded from semantics to spare the
        // Windows accessibility bridge.
        ExcludeSemantics(
          child: Text(
            coords,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: AppText.mono.copyWith(
              fontSize: 14.5,
              fontWeight: FontWeight.w800,
              fontFeatures: const [FontFeature.tabularFigures()],
              color: AppColors.foreground,
            ),
          ),
        ),
        Text(
          sub,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: AppText.mono.copyWith(
            fontSize: 11,
            fontWeight: FontWeight.w600,
            fontFeatures: const [FontFeature.tabularFigures()],
            color: AppColors.mutedForeground,
          ),
        ),
      ],
    );
  }
}
