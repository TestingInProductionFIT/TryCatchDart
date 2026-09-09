import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../flights/replay_controller.dart';
import '../../src/geo/geo.dart';
import '../../src/telemetry/telemetry_store.dart';
import '../../theme/app_colors.dart';
import '../../theme/widgets/waiting_for_data.dart';

/// Position panel in the centred widget language (state machine, max
/// altitude): each fix gets a tinted card with the micro label on top, the
/// coordinates big and centred, altitude below, and a copy button writing
/// `lat, lon` (Google Maps format) to the clipboard.
///
/// Dead reckoning is a live-only gap filler — during a replay only the GPS
/// card shows.
class StatsWidget extends ConsumerWidget {
  const StatsWidget({super.key});

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
        ? _mapsFormat(latest.latitude, latest.longitude)
        : '—';
    final gpsCopy = latest.gpsHasFix
        ? _mapsPlain(latest.latitude, latest.longitude)
        : null;
    final gpsSub = [
      _metres(latest.gpsAltitude),
      if (gpsDistance != null)
        gpsDistance >= 1000
            ? '${(gpsDistance / 1000).toStringAsFixed(2)} km from site'
            : '${gpsDistance.toStringAsFixed(0)} m from site',
    ].join(' · ');

    if (replaying) {
      return _PositionCard(
        label: gpsLabel,
        primary: gpsCoords,
        secondary: gpsSub,
        copyText: gpsCopy,
      );
    }

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
    final drCoords =
        dr == null ? '—' : _mapsFormat(dr.latitude, dr.longitude);
    final drCopy =
        dr == null ? null : _mapsPlain(dr.latitude, dr.longitude);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: _PositionCard(
            label: gpsLabel,
            primary: gpsCoords,
            secondary: gpsSub,
            copyText: gpsCopy,
          ),
        ),
        const SizedBox(height: 8),
        Expanded(
          child: _PositionCard(
            label: linkStale
                ? 'Dead reckoning · extrapolating'
                : 'Dead reckoning',
            primary: drCoords,
            secondary: _metres(drAlt),
            copyText: drCopy,
          ),
        ),
      ],
    );
  }

  static String _metres(double? m) => m == null
      ? '—'
      : '${m.toStringAsFixed(m.abs() >= 100 ? 0 : 1)} m';

  /// Display format with degree marks.
  static String _mapsFormat(double lat, double lon) =>
      '${lat.toStringAsFixed(5)}°, ${lon.toStringAsFixed(5)}°';

  /// Plain paste format — Google Maps search takes it as-is.
  static String _mapsPlain(double lat, double lon) =>
      '${lat.toStringAsFixed(6)}, ${lon.toStringAsFixed(6)}';
}

/// One centred fix card: micro label on top, big coordinates in the middle,
/// altitude line + copy button at the bottom.
class _PositionCard extends StatelessWidget {
  final String label;
  final String primary;
  final String secondary;

  /// When non-null, a copy button copies this text (Google Maps format).
  final String? copyText;

  const _PositionCard({
    required this.label,
    required this.primary,
    required this.secondary,
    this.copyText,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: AppColors.muted,
        borderRadius: BorderRadius.circular(AppDimens.radiusSmall),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Text(
            label.toUpperCase(),
            textAlign: TextAlign.center,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style:
                AppText.microLabel.copyWith(fontSize: 9, letterSpacing: 1.2),
          ),
          Expanded(
            child: Center(
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(
                  primary,
                  textAlign: TextAlign.center,
                  style: AppText.mono.copyWith(
                    fontSize: 17,
                    fontWeight: FontWeight.w800,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ),
            ),
          ),
          Text(
            secondary,
            textAlign: TextAlign.center,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: AppText.mono.copyWith(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: AppColors.mutedForeground,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
          if (copyText != null) ...[
            const SizedBox(height: 4),
            _CopyButton(text: copyText!),
          ],
        ],
      ),
    );
  }
}

class _CopyButton extends StatelessWidget {
  final String text;

  const _CopyButton({required this.text});

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: 'Copy "$text" (Google Maps format)',
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: InkWell(
          onTap: () async {
            await Clipboard.setData(ClipboardData(text: text));
            if (context.mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text('Copied $text'),
                  duration: const Duration(seconds: 1),
                ),
              );
            }
          },
          borderRadius: BorderRadius.circular(4),
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.copy, size: 12, color: AppColors.mutedForeground),
                SizedBox(width: 4),
                Text(
                  'COPY',
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 1,
                    color: AppColors.mutedForeground,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
