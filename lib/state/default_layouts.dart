import './layout_tree.dart';
import './workspace_models.dart';

/// Factory default workspace arrangements.
///
/// Snapshot of the arranged workspaces (Flight control, Pre-flight check,
/// Recovery, Replay) promoted to defaults. Ratios and orientations are
/// preserved verbatim; IDs are freshly generated via [GridIds.next] at
/// construction time.
abstract final class DefaultLayouts {
  /// All factory default workspaces in order.
  static List<Workspace> all() => [
        flight(),
        prep(),
        recovery(),
        replay(),
      ];

  /// Default flight layout for the live dashboard.
  static Workspace flight() => Workspace(
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
  static Workspace prep() => Workspace(
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
  static Workspace recovery() => Workspace(
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
  static Workspace replay() => Workspace(
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
