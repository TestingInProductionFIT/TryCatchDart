import 'package:flutter/material.dart';

import '../../state/workspace_models.dart' show leafCameraModeKey;
import '../tiles/shared/flight_3d_common.dart'
    show FlightCameraMode, tryParseFlightCameraMode;

export '../../state/workspace_models.dart' show leafCameraModeKey;
export '../tiles/shared/flight_3d_common.dart'
    show FlightCameraMode, tryParseFlightCameraMode;

/// Carries one workspace leaf's identity and persisted settings down to its
/// tile, so stateful tiles (the 3D flight views' camera mode) can restore
/// their selection from the save file and report changes back for
/// persistence. Tiles without a scope (picker previews, tests) use their
/// built-in defaults and report nowhere.
class TileLeafScope extends InheritedWidget {
  /// Stable id of the leaf hosting the tile.
  final String tileId;

  /// Persisted camera mode for the 3D flight tiles, or `null` when the leaf
  /// stores none (fresh tile → default mode).
  final FlightCameraMode? cameraMode;

  /// Called when the tile's camera mode changes, so the workspace store can
  /// write it back to the leaf. `null` outside the workspace grid.
  final ValueChanged<FlightCameraMode>? onCameraMode;

  const TileLeafScope({
    super.key,
    required this.tileId,
    required super.child,
    this.cameraMode,
    this.onCameraMode,
  });

  /// Builds a scope from a leaf's settings bag ([leafCameraModeKey]).
  factory TileLeafScope.fromSettings({
    Key? key,
    required String tileId,
    required Map<String, String> settings,
    required ValueChanged<FlightCameraMode>? onCameraMode,
    required Widget child,
  }) =>
      TileLeafScope(
        key: key,
        tileId: tileId,
        cameraMode: tryParseFlightCameraMode(settings[leafCameraModeKey]),
        onCameraMode: onCameraMode,
        child: child,
      );

  static TileLeafScope? of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<TileLeafScope>();

  @override
  bool updateShouldNotify(covariant TileLeafScope oldWidget) =>
      tileId != oldWidget.tileId || cameraMode != oldWidget.cameraMode;
}
