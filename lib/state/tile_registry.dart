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
import '../ui/tiles/map_tile.dart';
import '../ui/tiles/max_altitude_tile.dart';
import '../ui/tiles/parachute_tile.dart';
import '../ui/tiles/rocket_3d_tile.dart';
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
      minSize: const Size(240, 200),
      immersive: true,
      builder: (context) => Rocket3dTile(),
    ),
    TileDescriptor(
      id: 'map',
      title: 'Map',
      description: 'GPS track, dead reckoning and launch site',
      minSize: const Size(280, 200),
      immersive: true,
      builder: (context) => MapTile(),
    ),
    TileDescriptor(
      id: 'flight_3d',
      title: 'Flight 3D',
      description: '3D flight trail with launch site and camera modes',
      minSize: const Size(300, 220),
      immersive: true,
      builder: (context) => Flight3dTile(),
    ),
    TileDescriptor(
      id: 'flight_3d_sat',
      title: 'Flight 3D Satellite',
      description: '3D flight trail over satellite imagery (needs internet)',
      minSize: const Size(320, 240),
      immersive: true,
      builder: (context) => Flight3dSatelliteTile(),
    ),
    TileDescriptor(
      id: 'stats',
      title: 'Position',
      description: 'GPS and dead-reckoning positions with copy',
      minSize: const Size(220, 170),
      builder: (context) => StatsTile(),
    ),
    TileDescriptor(
      id: 'max_alt',
      title: 'Max altitude',
      description: 'Peak barometric altitude this session',
      minSize: const Size(200, 110),
      builder: (context) => MaxAltitudeTile(),
    ),
    TileDescriptor(
      id: 'altitude_chart',
      title: 'Altitude',
      description: 'Barometric altitude over time',
      minSize: const Size(220, 140),
      builder: (context) => AltitudeChartTile(),
    ),
    TileDescriptor(
      id: 'velocity_chart',
      title: 'Velocity',
      description: 'Horizontal, vertical and total speed',
      minSize: const Size(220, 140),
      builder: (context) => VelocityChartTile(),
    ),
    TileDescriptor(
      id: 'acceleration_chart',
      title: 'Acceleration',
      description: 'Horizontal and total acceleration',
      minSize: const Size(220, 140),
      builder: (context) => AccelerationChartTile(),
    ),
    TileDescriptor(
      id: 'battery_chart',
      title: 'Battery',
      description: 'Battery voltage over time',
      minSize: const Size(220, 140),
      builder: (context) => BatteryChartTile(),
    ),
    TileDescriptor(
      id: 'fsm',
      title: 'State machine',
      description: 'Flight software state and timeline',
      minSize: const Size(240, 240),
      builder: (context) => FsmTile(),
    ),
    TileDescriptor(
      id: 'parachute',
      title: 'Parachute',
      description: 'Parachute deployment state',
      minSize: const Size(140, 110),
      builder: (context) => ParachuteTile(),
    ),
    TileDescriptor(
      id: 'hall_sensor',
      title: 'Hall sensor',
      description: 'Breakaway wire sensor readout',
      minSize: const Size(220, 140),
      builder: (context) => HallSensorTile(),
    ),
    TileDescriptor(
      id: 'channel_health',
      title: 'Channel health',
      description: 'Undecodable traffic on this frequency',
      minSize: const Size(260, 180),
      builder: (context) => ChannelHealthTile(),
    ),
    TileDescriptor(
      id: 'control_panel',
      title: 'Control panel',
      description: 'Two-click commands to the rocket',
      minSize: const Size(420, 200),
      builder: (context) => ControlPanelTile(),
    ),
  ];

  static TileDescriptor? byId(String id) {
    for (final d in all) {
      if (d.id == id) return d;
    }
    return null;
  }

  static Size minSizeOf(String tileType) =>
      byId(tileType)?.minSize ?? const Size(180, 120);

  /// Factory layout used for the initial workspace and after a reset.
  ///
  /// A balanced alternating tree over the tile order.
  static Workspace defaultFlightLayout() => Workspace(
        id: GridIds.next(),
        name: 'Flight view',
        root: treeFromOrder(_leaves(const [
          'rocket_3d',
          'map',
          'flight_3d',
          'flight_3d_sat',
          'stats',
          'max_alt',
          'fsm',
          'parachute',
          'altitude_chart',
          'velocity_chart',
          'battery_chart',
          'hall_sensor',
          'acceleration_chart',
          'channel_health',
          'control_panel',
        ])),
      );

  /// Secondary default workspace for pre-launch checks.
  static Workspace defaultPrepLayout() => Workspace(
        id: GridIds.next(),
        name: 'Prep',
        root: treeFromOrder(_leaves(const [
          'control_panel',
          'fsm',
          'parachute',
          'stats',
          'max_alt',
          'battery_chart',
          'hall_sensor',
          'channel_health',
        ])),
      );

  /// Replay workspace: large Flight 3D on the left, flight data on the
  /// right — no control panel (commands are disabled during replay) and no
  /// dead-reckoning trail.
  static Workspace defaultReplayLayout() {
    LeafNode leaf(String tileType) =>
        LeafNode(tileId: GridIds.next(), tileType: tileType);

    final flight3d = leaf('flight_3d');
    final map = leaf('map');
    final altitude = leaf('altitude_chart');
    final velocity = leaf('velocity_chart');
    final position = leaf('stats');
    final fsm = leaf('fsm');
    final parachute = leaf('parachute');
    final maxAlt = leaf('max_alt');
    final battery = leaf('battery_chart');

    // Right column: map on top, charts in the middle, position row at bottom.
    final chartRow = SplitNode(
      vertical: false,
      ratio: 0.5,
      a: altitude,
      b: velocity,
    );
    final posRow = SplitNode(
      vertical: false,
      ratio: 0.55,
      a: position,
      b: fsm,
    );
    final metaRow = SplitNode(
      vertical: false,
      ratio: 0.5,
      a: SplitNode(
        vertical: false,
        ratio: 0.5,
        a: maxAlt,
        b: parachute,
      ),
      b: battery,
    );
    final bottomStack = SplitNode(
      vertical: true,
      ratio: 0.42,
      a: chartRow,
      b: SplitNode(
        vertical: true,
        ratio: 0.62,
        a: posRow,
        b: metaRow,
      ),
    );
    final rightColumn = SplitNode(
      vertical: true,
      ratio: 0.4,
      a: map,
      b: bottomStack,
    );
    final root = SplitNode(
      vertical: false,
      ratio: 0.58,
      a: flight3d,
      b: rightColumn,
    );
    return Workspace(id: GridIds.next(), name: 'Replay', root: root);
  }

  static List<LeafNode> _leaves(List<String> tileTypes) =>
      [for (final t in tileTypes) LeafNode(tileId: GridIds.next(), tileType: t)];
}
