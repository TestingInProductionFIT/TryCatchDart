import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../../flights/replay_controller.dart';
import '../../src/estimation/dead_reckoning.dart';
import '../../src/telemetry/telemetry_store.dart';
import '../../theme/app_colors.dart';
import '../../theme/widgets/tool_button.dart';
import 'map_tiles.dart';

/// Flight map: launch site, GPS track + live fix, dead-reckoning track + live
/// estimate. Tiles are fetched from OSM (internet required).
class MapWidget extends ConsumerStatefulWidget {
  const MapWidget({super.key});

  @override
  ConsumerState<MapWidget> createState() => _MapWidgetState();
}

class _MapWidgetState extends ConsumerState<MapWidget> {
  final MapController _mapController = MapController();
  bool _follow = false;
  bool _satellite = false;

  static final _streetTiles = buildStreetLayer();

  static final _satelliteTiles = buildSatelliteLayer();

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(telemetryStoreProvider);
    final site = ref.watch(effectiveLaunchSiteProvider);

    final latest = state.latest;
    final gpsPoint = (latest != null && latest.gpsHasFix)
        ? LatLng(latest.latitude, latest.longitude)
        : null;
    // Dead reckoning is a live-only gap filler — never shown during replay.
    final replaying = state.replaying;
    final dr = replaying ? null : state.deadReckoning;
    final drPoint = dr == null ? null : LatLng(dr.latitude, dr.longitude);

    final initialCenter = gpsPoint ??
        drPoint ??
        (site != null ? LatLng(site.latitude, site.longitude) : const LatLng(50.0755, 14.4378));

    if (_follow && gpsPoint != null) {
      _mapController.move(gpsPoint, _mapController.camera.zoom);
    }

    return Stack(
      children: [
        FlutterMap(
          mapController: _mapController,
          options: MapOptions(
            initialCenter: initialCenter,
            initialZoom: 15,
            minZoom: 3,
            maxZoom: 19,
            interactionOptions: const InteractionOptions(
              flags: InteractiveFlag.drag |
                  InteractiveFlag.scrollWheelZoom |
                  InteractiveFlag.pinchZoom,
            ),
          ),
          children: [
            _satellite ? _satelliteTiles : _streetTiles,
            PolylineLayer(
              polylines: [
                // Dead-reckoning: one dashed segment per GPS gap, each rooted
                // at the last known fix — never a single line from the pad.
                if (!replaying)
                  for (final segment in _drSegments(state))
                    if (segment.length > 1)
                      Polyline(
                        points: segment,
                        strokeWidth: 2.5,
                        color: AppColors.seriesDeadReckoning
                            .withValues(alpha: 0.75),
                        pattern: StrokePattern.dashed(segments: [6, 5]),
                      ),
                // GPS track.
                if (state.history.any((f) => f.gpsHasFix))
                  Polyline(
                    points: [
                      for (final f in state.history)
                        if (f.gpsHasFix) LatLng(f.latitude, f.longitude),
                    ],
                    strokeWidth: 3,
                    color: AppColors.seriesGpsTrack,
                  ),
              ],
            ),
            MarkerLayer(
              markers: [
                if (site != null)
                  Marker(
                    point: LatLng(site.latitude, site.longitude),
                    width: 30,
                    height: 30,
                    child: Tooltip(
                      message: 'Launch site: ${site.name}',
                      child: Icon(
                        Icons.flag,
                        size: 22,
                        color: AppColors.pinkDeep,
                        shadows: [
                          Shadow(color: Colors.white, blurRadius: 4),
                        ],
                      ),
                    ),
                  ),
                if (drPoint != null)
                  Marker(
                    point: drPoint,
                    width: 16,
                    height: 16,
                    child: Container(
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: AppColors.seriesDeadReckoning,
                          width: 2.5,
                        ),
                      ),
                    ),
                  ),
                if (gpsPoint != null)
                  Marker(
                    point: gpsPoint,
                    width: 16,
                    height: 16,
                    child: Container(
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: AppColors.seriesGpsTrack,
                        border: Border.all(color: Colors.white, width: 2),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.3),
                            blurRadius: 4,
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ],
        ),
        // Controls: follow, satellite toggle, zoom.
        Positioned(
          right: 8,
          top: 8,
          child: Column(
            children: [
              ToolFab(
                icon: _follow ? Icons.my_location : Icons.location_searching,
                tooltip: 'Follow rocket',
                active: _follow,
                onTap: () => setState(() => _follow = !_follow),
              ),
              const SizedBox(height: 6),
              ToolFab(
                icon: _satellite ? Icons.map_outlined : Icons.satellite_alt,
                tooltip: 'Toggle satellite',
                active: _satellite,
                onTap: () => setState(() => _satellite = !_satellite),
              ),
              const SizedBox(height: 6),
              ToolFab(
                icon: Icons.add,
                tooltip: 'Zoom in',
                active: false,
                onTap: () => _zoomBy(1),
              ),
              const SizedBox(height: 6),
              ToolFab(
                icon: Icons.remove,
                tooltip: 'Zoom out',
                active: false,
                onTap: () => _zoomBy(-1),
              ),
            ],
          ),
        ),
        // Attribution.
        Positioned(
          right: 4,
          bottom: 2,
          child: Text(
            _satellite ? satelliteAttribution : streetAttribution,
            style: TextStyle(
              fontSize: 9,
              color: Colors.black.withValues(alpha: 0.45),
            ),
          ),
        ),
        // Track legend.
        Positioned(
          left: 8,
          bottom: 8,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
            decoration: BoxDecoration(
              color: AppColors.card.withValues(alpha: 0.92),
              borderRadius: BorderRadius.circular(AppDimens.radiusSmall),
              border: Border.all(color: AppColors.border),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                _LegendRow(
                    color: AppColors.seriesGpsTrack, label: 'GPS', solid: true),
                if (!replaying) ...[
                  const SizedBox(height: 3),
                  _LegendRow(
                      color: AppColors.seriesDeadReckoning,
                      label: 'Dead reckoning',
                      solid: false),
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }

  void _zoomBy(double delta) {
    final camera = _mapController.camera;
    _mapController.move(
      camera.center,
      (camera.zoom + delta).clamp(3.0, 19.0),
    );
  }

  /// Dead-reckoning track split into one segment per GPS gap. Points within a
  /// gap arrive at 1 Hz, so a >3 s jump starts a new gap; each segment is
  /// rooted at the last known GPS fix so the dashed line grows out of where
  /// the fix was lost instead of trailing back to the pad (or bridging two
  /// unrelated gaps with a straight line).
  List<List<LatLng>> _drSegments(TelemetryState state) {
    final dr = state.deadReckoningHistory;
    final segments = <List<LatLng>>[];
    var current = <DrPosition>[];
    var prevMs = -1;

    void close() {
      if (current.isEmpty) return;
      final points = <LatLng>[
        ..._lastKnownFix(state, current.first.atMs),
        for (final p in current) LatLng(p.latitude, p.longitude),
      ];
      segments.add(points);
      current = <DrPosition>[];
    }

    for (var i = 0; i < dr.length; i++) {
      final p = dr.getChronological(i);
      if (prevMs >= 0 && p.atMs - prevMs > 3000) close();
      current.add(p);
      prevMs = p.atMs;
    }
    close();
    return segments;
  }

  /// Newest GPS fix at or before [atMs], as a single-element anchor list.
  List<LatLng> _lastKnownFix(TelemetryState state, int atMs) {
    for (final f in state.history.newestFirst()) {
      if (f.gpsHasFix && f.receivedAtMs <= atMs) {
        return [LatLng(f.latitude, f.longitude)];
      }
    }
    return const [];
  }
}

class _LegendRow extends StatelessWidget {
  final Color color;
  final String label;
  final bool solid;

  const _LegendRow({required this.color, required this.label, required this.solid});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 14,
          height: 3,
          decoration: BoxDecoration(
            color: solid ? color : null,
            border: solid
                ? null
                : Border(
                    top: BorderSide(
                        color: color,
                        width: 2,
                        strokeAlign: BorderSide.strokeAlignInside),
                  ),
          ),
        ),
        const SizedBox(width: 6),
        Text(
          label.toUpperCase(),
          style: AppText.microLabel.copyWith(
            fontSize: 8.5,
            letterSpacing: 1,
            color: AppColors.mutedForeground,
          ),
        ),
      ],
    );
  }
}
