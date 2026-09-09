import 'package:flutter/material.dart';

import 'layout_tree.dart';
import 'widgets/acceleration_chart_widget.dart';
import 'widgets/altitude_chart_widget.dart';
import 'widgets/battery_chart_widget.dart';
import 'widgets/control_panel_widget.dart';
import 'widgets/flight_3d_satellite_widget.dart';
import 'widgets/flight_3d_widget.dart';
import 'widgets/fsm_widget.dart';
import 'widgets/hall_sensor_widget.dart';
import 'widgets/map_widget.dart';
import 'widgets/max_altitude_widget.dart';
import 'widgets/parachute_widget.dart';
import 'widgets/pressure_chart_widget.dart';
import 'widgets/rocket_3d_widget.dart';
import 'widgets/stats_widget.dart';
import 'widgets/velocity_chart_widget.dart';
import 'workspace_models.dart';

/// Data-driven description of a dashboard widget type.
///
/// Adding a new widget to the whole app = create the widget class and append
/// one descriptor here; the "Add widget" picker and the default layouts pick
/// it up automatically.
class WidgetDescriptor {
  /// Stable registry id, persisted in workspace layouts.
  final String id;

  final String title;

  /// One-line description shown in the picker.
  final String description;

  /// Minimum usable size in logical pixels — the layout tree's divider drag
  /// never squeezes a widget below this.
  final Size minSize;

  final WidgetBuilder builder;

  const WidgetDescriptor({
    required this.id,
    required this.title,
    required this.description,
    required this.minSize,
    required this.builder,
  });
}

/// All dashboard widget types and the default workspace layouts.
abstract final class WidgetRegistry {
  static final List<WidgetDescriptor> all = [
    WidgetDescriptor(
      id: 'rocket_3d',
      title: '3D Rocket',
      description: 'Live orientation',
      minSize: const Size(240, 200),
      builder: (context) => Rocket3dWidget(),
    ),
    WidgetDescriptor(
      id: 'map',
      title: 'Map',
      description: 'GPS track, dead reckoning and launch site',
      minSize: const Size(280, 200),
      builder: (context) => MapWidget(),
    ),
    WidgetDescriptor(
      id: 'flight_3d',
      title: 'Flight 3D',
      description: '3D flight trail with launch site and camera modes',
      minSize: const Size(300, 220),
      builder: (context) => Flight3dWidget(),
    ),
    WidgetDescriptor(
      id: 'flight_3d_sat',
      title: 'Flight 3D Satellite',
      description: '3D flight trail over satellite imagery (needs internet)',
      minSize: const Size(320, 240),
      builder: (context) => Flight3dSatelliteWidget(),
    ),
    WidgetDescriptor(
      id: 'stats',
      title: 'Position',
      description: 'GPS and dead-reckoning positions with copy',
      minSize: const Size(220, 170),
      builder: (context) => StatsWidget(),
    ),
    WidgetDescriptor(
      id: 'max_alt',
      title: 'Max altitude',
      description: 'Peak barometric altitude this session',
      minSize: const Size(200, 110),
      builder: (context) => MaxAltitudeWidget(),
    ),
    WidgetDescriptor(
      id: 'altitude_chart',
      title: 'Altitude',
      description: 'Barometric altitude over time',
      minSize: const Size(220, 140),
      builder: (context) => AltitudeChartWidget(),
    ),
    WidgetDescriptor(
      id: 'velocity_chart',
      title: 'Velocity',
      description: 'Horizontal, vertical and total speed',
      minSize: const Size(220, 140),
      builder: (context) => VelocityChartWidget(),
    ),
    WidgetDescriptor(
      id: 'acceleration_chart',
      title: 'Acceleration',
      description: 'Horizontal and total acceleration',
      minSize: const Size(220, 140),
      builder: (context) => AccelerationChartWidget(),
    ),
    WidgetDescriptor(
      id: 'battery_chart',
      title: 'Battery',
      description: 'Battery voltage over time',
      minSize: const Size(220, 100),
      builder: (context) => BatteryChartWidget(),
    ),
    WidgetDescriptor(
      id: 'pressure_chart',
      title: 'Pressure',
      description: 'Static pressure over time (derived from baro altitude)',
      minSize: const Size(220, 140),
      builder: (context) => PressureChartWidget(),
    ),
    WidgetDescriptor(
      id: 'fsm',
      title: 'State machine',
      description: 'Flight software state and timeline',
      minSize: const Size(240, 170),
      builder: (context) => FsmWidget(),
    ),
    WidgetDescriptor(
      id: 'parachute',
      title: 'Parachute',
      description: 'Parachute deployment state',
      minSize: const Size(140, 110),
      builder: (context) => ParachuteWidget(),
    ),
    WidgetDescriptor(
      id: 'hall_sensor',
      title: 'Hall sensor',
      description: 'Breakaway wire sensor readout',
      minSize: const Size(220, 100),
      builder: (context) => HallSensorWidget(),
    ),
    WidgetDescriptor(
      id: 'control_panel',
      title: 'Control panel',
      description: 'Two-click commands to the rocket',
      minSize: const Size(420, 110),
      builder: (context) => ControlPanelWidget(),
    ),
  ];

  static WidgetDescriptor? byId(String id) {
    for (final d in all) {
      if (d.id == id) return d;
    }
    return null;
  }

  static Size minSizeOf(String typeId) =>
      byId(typeId)?.minSize ?? const Size(180, 120);

  /// Factory layout used for the initial workspace and after a reset.
  ///
  /// A balanced alternating tree over the widget order.
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
          'pressure_chart',
          'velocity_chart',
          'battery_chart',
          'hall_sensor',
          'acceleration_chart',
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
        ])),
      );

  /// Replay workspace: large Flight 3D on the left, flight data on the
  /// right — no control panel (commands are disabled during replay) and no
  /// dead-reckoning trail.
  static Workspace defaultReplayLayout() {
    LeafNode leaf(String typeId) =>
        LeafNode(widgetId: GridIds.next(), typeId: typeId);

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

  static List<LeafNode> _leaves(List<String> typeIds) =>
      [for (final t in typeIds) LeafNode(widgetId: GridIds.next(), typeId: t)];
}
