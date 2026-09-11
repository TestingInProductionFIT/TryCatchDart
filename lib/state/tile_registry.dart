import 'package:flutter/material.dart';

import './layout_tree.dart';
import '../ui/tiles/acceleration_chart_tile.dart';
import '../ui/tiles/altitude_chart_tile.dart';
import '../ui/tiles/battery_chart_tile.dart';
import '../ui/tiles/channel_health_tile.dart';
import '../ui/tiles/control_panel_tile.dart';
import '../ui/tiles/flight_3d_satellite_tile.dart';
import '../ui/tiles/flight_3d_tile.dart';
import '../ui/tiles/fsm_tile.dart';
import '../ui/tiles/hall_sensor_tile.dart';
import '../ui/tiles/highlights_tile.dart';
import '../ui/tiles/map_tile.dart';
import '../ui/tiles/max_altitude_tile.dart';
import '../ui/tiles/nosecone_tile.dart';
import '../ui/tiles/rocket_3d_tile.dart';
import '../ui/tiles/dead_reckoning_tile.dart';
import '../ui/tiles/events_tile.dart';
import '../ui/tiles/stats_tile.dart';
import '../ui/tiles/velocity_chart_tile.dart';
import './workspace_models.dart';

/// Data-driven description of a dashboard tile type.
///
/// Adding a new tile to the whole app = create the tile class and append
/// one descriptor here; the "Add tile" picker and the default layouts pick
/// it up automatically.
class TileDescriptor {
  /// Stable registry id, persisted in workspace layouts.
  final String id;

  final String title;

  /// One-line description shown in the picker.
  final String description;

  /// Picker glyph.
  final IconData icon;

  /// Minimum usable size in logical pixels — the layout tree's divider drag
  /// never squeezes a tile below this.
  final Size minSize;

  /// Immersive tiles (map, 3D views) render edge-to-edge: the card drops its
  /// content padding so the render touches the card border (the header
  /// strip stays).
  final bool immersive;

  final WidgetBuilder builder;

  const TileDescriptor({
    required this.id,
    required this.title,
    required this.description,
    required this.icon,
    required this.minSize,
    this.immersive = false,
    required this.builder,
  });
}

/// All dashboard tile types and the default workspace layouts.
abstract final class TileRegistry {
  static final List<TileDescriptor> all = [
    TileDescriptor(
      id: 'rocket_3d',
      title: '3D Rocket',
      description: 'Live orientation',
      icon: Icons.rocket_launch_outlined,
      minSize: const Size(150, 110),
      immersive: true,
      builder: (context) => Rocket3dTile(),
    ),
    TileDescriptor(
      id: 'map',
      title: 'Map',
      description: 'GPS track, dead reckoning and launch site',
      icon: Icons.map_outlined,
      minSize: const Size(150, 110),
      immersive: true,
      builder: (context) => MapTile(),
    ),
    TileDescriptor(
      id: 'flight_3d',
      title: 'Flight 3D',
      description: '3D flight trail with launch site and camera modes',
      icon: Icons.view_in_ar_outlined,
      minSize: const Size(170, 120),
      immersive: true,
      builder: (context) => Flight3dTile(),
    ),
    TileDescriptor(
      id: 'flight_3d_sat',
      title: 'Flight 3D Satellite',
      description: '3D flight trail over satellite imagery (needs internet)',
      icon: Icons.satellite_alt_outlined,
      minSize: const Size(170, 120),
      immersive: true,
      builder: (context) => Flight3dSatelliteTile(),
    ),
    TileDescriptor(
      id: 'stats',
      title: 'GPS position',
      description: 'GPS position with copy',
      icon: Icons.place_outlined,
      minSize: const Size(130, 80),
      builder: (context) => StatsTile(),
    ),
    TileDescriptor(
      id: 'dead_reckoning',
      title: 'Dead reckoning',
      description: 'Estimated position during packet loss (live only)',
      icon: Icons.explore_outlined,
      minSize: const Size(130, 80),
      builder: (context) => DeadReckoningTile(),
    ),
    TileDescriptor(
      id: 'max_alt',
      title: 'Max altitude',
      description: 'Peak barometric altitude this session',
      icon: Icons.arrow_upward,
      minSize: const Size(110, 64),
      builder: (context) => MaxAltitudeTile(),
    ),
    TileDescriptor(
      id: 'highlights',
      title: 'Highlights',
      description: 'Flight extremes: ascent, descent, speed, acceleration (+ replay drift/altitude)',
      icon: Icons.emoji_events_outlined,
      minSize: const Size(140, 80),
      builder: (context) => HighlightsTile(),
    ),
    TileDescriptor(
      id: 'altitude_chart',
      title: 'Altitude',
      description: 'Barometric altitude over time',
      icon: Icons.show_chart,
      minSize: const Size(130, 70),
      builder: (context) => AltitudeChartTile(),
    ),
    TileDescriptor(
      id: 'velocity_chart',
      title: 'Velocity',
      description: 'Horizontal, vertical and total speed',
      icon: Icons.speed_outlined,
      minSize: const Size(130, 70),
      builder: (context) => VelocityChartTile(),
    ),
    TileDescriptor(
      id: 'acceleration_chart',
      title: 'Acceleration',
      description: 'Vertical and total acceleration',
      icon: Icons.trending_up,
      minSize: const Size(130, 70),
      builder: (context) => AccelerationChartTile(),
    ),
    TileDescriptor(
      id: 'battery_chart',
      title: 'Battery',
      description: 'Battery voltage over time',
      icon: Icons.battery_charging_full_outlined,
      minSize: const Size(130, 70),
      builder: (context) => BatteryChartTile(),
    ),
    TileDescriptor(
      id: 'fsm',
      title: 'State machine',
      description: 'Flight software state and timeline',
      icon: Icons.account_tree_outlined,
      minSize: const Size(150, 120),
      builder: (context) => FsmTile(),
    ),
    TileDescriptor(
      id: 'events',
      title: 'Events',
      description: 'Flight milestones: launch, apogee, parachute, touchdown',
      icon: Icons.flag_outlined,
      minSize: const Size(140, 90),
      builder: (context) => EventsTile(),
    ),
    TileDescriptor(
      id: 'nosecone',
      title: 'Nose cone',
      description: 'Nose-cone lock state',
      icon: Icons.lock_outlined,
      minSize: const Size(110, 64),
      builder: (context) => NoseconeTile(),
    ),
    TileDescriptor(
      id: 'hall_sensor',
      title: 'Hall sensor',
      description: 'Breakaway wire sensor readout',
      icon: Icons.sensors_outlined,
      minSize: const Size(130, 70),
      builder: (context) => HallSensorTile(),
    ),
    TileDescriptor(
      id: 'channel_health',
      title: 'Channel health',
      description: 'Undecodable traffic on this frequency',
      icon: Icons.wifi_tethering_outlined,
      minSize: const Size(140, 80),
      builder: (context) => ChannelHealthTile(),
    ),
    TileDescriptor(
      id: 'control_panel',
      title: 'Control panel',
      description: 'Two-click commands to the rocket',
      icon: Icons.gamepad_outlined,
      minSize: const Size(190, 110),
      builder: (context) => ControlPanelTile(),
    ),
  ];

  static TileDescriptor? byId(String id) {
    for (final d in all) {
      if (d.id == id) return d;
    }
    // Legacy workspaces persisted the nose-cone tile as 'parachute'.
    if (id == 'parachute') return byId('nosecone');
    return null;
  }

  /// Hard floor under every tile so dividers never squeeze a tile into
  /// an unpaintable strip. Kept deliberately low — tiles shed chrome
  /// (legends, grids collapse) instead of overflowing.
  static const Size absoluteFloor = Size(110, 64);

  static Size minSizeOf(String tileType) {
    final min = byId(tileType)?.minSize ?? const Size(120, 70);
    return Size(
      min.width > absoluteFloor.width ? min.width : absoluteFloor.width,
      min.height > absoluteFloor.height ? min.height : absoluteFloor.height,
    );
  }

  /// Factory layouts — snapshot of the user's arranged workspaces
  /// (Flight control, Pre-flight check, Recovery, Replay), promoted to
  /// defaults. Ratios/orientations are preserved verbatim; ids are fresh
  /// via [GridIds.next] at construction time.
  static Workspace defaultFlightLayout() => Workspace(
    id: GridIds.next(),
    name: 'Flight control',
    root: SplitNode(
      vertical: false,
      ratio: 0.6505319148936172,
      a: SplitNode(
        vertical: false,
        ratio: 0.6330814441645675,
        a: SplitNode(
          vertical: true,
          ratio: 0.5,
          a: LeafNode(tileId: GridIds.next(), tileType: 'rocket_3d'),
          b: LeafNode(tileId: GridIds.next(), tileType: 'map'),
        ),
        b: SplitNode(
          vertical: true,
          ratio: 0.46879258653584105,
          a: SplitNode(
            vertical: true,
            ratio: 0.8007246376811616,
            a: LeafNode(tileId: GridIds.next(), tileType: 'highlights'),
            b: SplitNode(
              vertical: false,
              ratio: 0.5,
              a: LeafNode(tileId: GridIds.next(), tileType: 'max_alt'),
              b: LeafNode(tileId: GridIds.next(), tileType: 'nosecone'),
            ),
          ),
          b: SplitNode(
            vertical: true,
            ratio: 0.2939632545931769,
            a: SplitNode(
              vertical: false,
              ratio: 0.5,
              a: LeafNode(tileId: GridIds.next(), tileType: 'altitude_chart'),
              b: LeafNode(tileId: GridIds.next(), tileType: 'velocity_chart'),
            ),
            b: LeafNode(tileId: GridIds.next(), tileType: 'altitude_chart'),
          ),
        ),
      ),
      b: SplitNode(
        vertical: true,
        ratio: 0.5,
        a: LeafNode(tileId: GridIds.next(), tileType: 'fsm'),
        b: LeafNode(tileId: GridIds.next(), tileType: 'control_panel'),
      ),
    ),
  );

  /// Secondary default workspace for pre-launch checks.
  static Workspace defaultPrepLayout() => Workspace(
    id: GridIds.next(),
    name: 'Pre-flight check',
    root: SplitNode(
      vertical: false,
      ratio: 0.5239361702127658,
      a: SplitNode(
        vertical: false,
        ratio: 0.5,
        a: SplitNode(
          vertical: true,
          ratio: 0.5,
          a: SplitNode(
            vertical: true,
            ratio: 0.15004179437169118,
            a: LeafNode(tileId: GridIds.next(), tileType: 'hall_sensor'),
            b: LeafNode(tileId: GridIds.next(), tileType: 'hall_sensor'),
          ),
          b: SplitNode(
            vertical: true,
            ratio: 0.18793535803845174,
            a: LeafNode(tileId: GridIds.next(), tileType: 'battery_chart'),
            b: LeafNode(tileId: GridIds.next(), tileType: 'battery_chart'),
          ),
        ),
        b: SplitNode(
          vertical: true,
          ratio: 0.5,
          a: LeafNode(tileId: GridIds.next(), tileType: 'nosecone'),
          b: LeafNode(tileId: GridIds.next(), tileType: 'channel_health'),
        ),
      ),
      b: SplitNode(
        vertical: true,
        ratio: 0.4989845171840794,
        a: LeafNode(tileId: GridIds.next(), tileType: 'fsm'),
        b: LeafNode(tileId: GridIds.next(), tileType: 'control_panel'),
      ),
    ),
  );

  /// Recovery workspace: GPS + dead-reckoning positions on the left, map
  /// below them, satellite 3D on the right.
  static Workspace defaultRecoveryLayout() => Workspace(
    id: GridIds.next(),
    name: 'Recovery',
    root: SplitNode(
      vertical: false,
      ratio: 0.5,
      a: SplitNode(
        vertical: true,
        ratio: 0.26996456800217977,
        a: SplitNode(
          vertical: false,
          ratio: 0.5,
          a: LeafNode(tileId: GridIds.next(), tileType: 'stats'),
          b: LeafNode(tileId: GridIds.next(), tileType: 'dead_reckoning'),
        ),
        b: LeafNode(tileId: GridIds.next(), tileType: 'map'),
      ),
      b: LeafNode(tileId: GridIds.next(), tileType: 'flight_3d_sat'),
    ),
  );

  /// Replay workspace: satellite 3D on the left, charts + highlights on the
  /// right.
  static Workspace defaultReplayLayout() => Workspace(
    id: GridIds.next(),
    name: 'Replay',
    root: SplitNode(
      vertical: false,
      ratio: 0.530851063829787,
      a: LeafNode(tileId: GridIds.next(), tileType: 'flight_3d_sat'),
      b: SplitNode(
        vertical: false,
        ratio: 0.5020102109026083,
        a: SplitNode(
          vertical: true,
          ratio: 0.6929681112019618,
          a: SplitNode(
            vertical: true,
            ratio: 0.4969224962877054,
            a: LeafNode(tileId: GridIds.next(), tileType: 'altitude_chart'),
            b: LeafNode(tileId: GridIds.next(), tileType: 'velocity_chart'),
          ),
          b: LeafNode(tileId: GridIds.next(), tileType: 'acceleration_chart'),
        ),
        b: SplitNode(
          vertical: true,
          ratio: 0.4969224962877054,
          a: LeafNode(tileId: GridIds.next(), tileType: 'highlights'),
          b: LeafNode(tileId: GridIds.next(), tileType: 'map'),
        ),
      ),
    ),
  );
}
