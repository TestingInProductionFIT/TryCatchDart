import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:serial/serial.dart' show TelemetryFrame;

import '../../core/format.dart';
import '../../core/geo.dart';
import '../../state/replay_controller.dart';
import '../../state/telemetry_store.dart';
import '../../theme/app_colors.dart';
import '../components/position_readout.dart';
import '../components/waiting_for_data.dart';

/// Dead-reckoning estimate panel: the ground-side gap filler that bridges
/// GPS / link outages by integrating the last known velocity.
///
/// Live-only and loss-gated:
/// * disabled during replays (the store never computes dead reckoning then
///   — the tile says so instead of showing a frozen estimate);
/// * while the link is healthy the tile reports link-nominal instead of
///   duplicating the GPS fix — the estimate only appears on packet loss
///   (no packets for over [TelemetryStore.drStaleMs], the same threshold
///   the store extrapolator, the GPS tile and the 3D views use).
///
/// On loss the tile shows the extrapolated coordinates plus altitude,
/// drift (horizontal distance from the launch site) and the 3D distance
/// from the last known GPS position, so recovery knows both how far the
/// rocket drifted and how far the estimate has travelled since the fix.
/// The readout clamps at the site MSL: the blind velocity integral can sink
/// below ground after a landing or a long gap.
///
/// Centred in the available space; the whole readout scales down in short
/// tiles instead of clipping.
class DeadReckoningTile extends ConsumerWidget {
  const DeadReckoningTile({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Dead reckoning is a live-only gap filler — replays show the recorded
    // GPS track as-is (no synthetic estimates). Guard covers custom layouts
    // that still contain this tile; the Replay workspace omits it entirely.
    if (ref.watch(replayProvider).isActive) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.block, size: 22, color: AppColors.faint),
            const SizedBox(height: 8),
            Text(
              'Disabled during replay',
              style:
                  TextStyle(fontSize: 12, color: AppColors.mutedForeground),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      );
    }

    final state = ref.watch(telemetryStoreProvider);
    final latest = state.latest;
    final site = ref.watch(effectiveLaunchSiteProvider);

    if (latest == null) {
      return Center(child: WaitingForData());
    }

    // Packet loss = the link itself is silent, not just the GPS fix.
    final linkStale = DateTime.now().millisecondsSinceEpoch -
            latest.receivedAtMs >
        TelemetryStore.drStaleMs;

    if (!linkStale) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.satellite_alt_outlined,
                size: 22, color: AppColors.success),
            const SizedBox(height: 8),
            Text(
              'LINK HEALTHY',
              style: AppText.microLabel.copyWith(
                fontSize: 10,
                letterSpacing: 1.6,
                color: AppColors.success,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 3),
            Text(
              'No packet loss — estimate hidden',
              style:
                  TextStyle(fontSize: 11, color: AppColors.mutedForeground),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      );
    }

    final dr = state.deadReckoning;
    if (dr == null) {
      return Center(
        child: WaitingForData(hint: 'Signal lost — no fix to project yet'),
      );
    }

    final drAlt = site == null
        ? dr.altitude
        : dr.altitude < site.altitudeMsl
            ? site.altitudeMsl
            : dr.altitude;

    final drift = site == null
        ? null
        : haversineDistanceM(
            site.latitude, site.longitude, dr.latitude, dr.longitude);

    // Last known GPS position: the newest frame in history carrying a fix
    // (the latest frame itself usually has none — that is why the estimate
    // is showing). The 3D distance from it is what recovery walks.
    TelemetryFrame? lastFix;
    for (final frame in state.history.newestFirst()) {
      if (frame.gpsHasFix) {
        lastFix = frame;
        break;
      }
    }
    final travelled = lastFix == null
        ? null
        : distance3dM(
            lastFix.latitude,
            lastFix.longitude,
            lastFix.gpsAltitude,
            dr.latitude,
            dr.longitude,
            drAlt,
          );

    return PositionReadout(
      coords: formatLatLon(dr.latitude, dr.longitude),
      copyText: formatLatLonPlain(dr.latitude, dr.longitude),
      qrLatitude: dr.latitude,
      qrLongitude: dr.longitude,
      qrTitle: 'Dead reckoning',
      details: [
        (text: 'Altitude ${formatAltitudeM(drAlt)}', tooltip: null),
        if (drift != null)
          (
            text: 'Drift ${formatDistanceM(drift)}',
            tooltip: 'Horizontal distance from the launch site',
          ),
      ],
      footer: travelled == null
          ? null
          : (
              text:
                  '${formatDistanceM(travelled)} from last known position',
              tooltip:
                  '3D distance from the last GPS fix, altitude included',
            ),
    );
  }
}
