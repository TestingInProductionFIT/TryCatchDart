import 'package:flutter/material.dart';

import 'layout_tree.dart';
import 'widgets/acceleration_chart_widget.dart';
import 'widgets/altitude_chart_widget.dart';
import 'widgets/battery_chart_widget.dart';
import 'widgets/control_panel_widget.dart';
import 'widgets/flight_3d_widget.dart';
import 'widgets/fsm_widget.dart';
import 'widgets/hall_sensor_widget.dart';
import 'widgets/map_widget.dart';
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
      description: 'Live orientation and parachute state',
      minSize: const Size(240, 200),
      builder: (context) => const Rocket3dWidget(),
    ),
    WidgetDescriptor(
      id: 'map',
      title: 'Map',
      description: 'GPS track, dead reckoning and launch site',
      minSize: const Size(280, 200),
      builder: (context) => const MapWidget(),
    ),
    WidgetDescriptor(
      id: 'flight_3d',
      title: 'Flight 3D',
      description: '3D flight trail with launch site and camera modes',
      minSize: const Size(300, 220),
      builder: (context) => const Flight3dWidget(),
    ),
    WidgetDescriptor(
      id: 'stats',
      title: 'Stats',
      description: 'Positions, max height, distance from site',
      minSize: const Size(220, 170),
      builder: (context) => const StatsWidget(),
    ),
    WidgetDescriptor(
      id: 'altitude_chart',
      title: 'Altitude',
      description: 'Barometric altitude over time',
      minSize: const Size(220, 140),
      builder: (context) => const AltitudeChartWidget(),
    ),
    WidgetDescriptor(
      id: 'velocity_chart',
      title: 'Velocity',
      description: 'Horizontal, vertical and total speed',
      minSize: const Size(220, 140),
      builder: (context) => const VelocityChartWidget(),
    ),
    WidgetDescriptor(
      id: 'acceleration_chart',
      title: 'Acceleration',
      description: 'Horizontal and total acceleration',
      minSize: const Size(220, 140),
      builder: (context) => const AccelerationChartWidget(),
    ),
    WidgetDescriptor(
      id: 'battery_chart',
      title: 'Battery',
      description: 'Battery voltage over time',
      minSize: const Size(220, 100),
      builder: (context) => const BatteryChartWidget(),
    ),
    WidgetDescriptor(
      id: 'fsm',
      title: 'State machine',
      description: 'Flight software state and timeline',
      minSize: const Size(240, 120),
      builder: (context) => const FsmWidget(),
    ),
    WidgetDescriptor(
      id: 'hall_sensor',
      title: 'Hall sensor',
      description: 'Breakaway wire sensor readout',
      minSize: const Size(220, 100),
      builder: (context) => const HallSensorWidget(),
    ),
    WidgetDescriptor(
      id: 'control_panel',
      title: 'Control panel',
      description: 'Two-click commands to the rocket',
      minSize: const Size(420, 110),
      builder: (context) => const ControlPanelWidget(),
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
          'stats',
          'fsm',
          'altitude_chart',
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
          'stats',
          'battery_chart',
          'hall_sensor',
        ])),
      );

  static List<LeafNode> _leaves(List<String> typeIds) =>
      [for (final t in typeIds) LeafNode(widgetId: GridIds.next(), typeId: t)];
}
