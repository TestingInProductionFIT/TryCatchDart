import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../theme/app_colors.dart';
import '../components/app_card.dart';
import './dashboard_screen.dart' show showTilePicker;
import '../../state/layout_tree.dart';
import '../../state/tile_registry.dart';
import '../../state/workspace_controller.dart';
import '../../state/workspace_models.dart';

/// Renders the active workspace as a KD-tree tiling.
///
/// Internal nodes split horizontally/vertically at draggable ratios that
/// respect each tile's minimum size. In edit mode tiles can be dragged
/// onto each other to swap places, and removed via the card header.
class WorkspaceGrid extends ConsumerStatefulWidget {
  final bool editMode;

  const WorkspaceGrid({super.key, required this.editMode});

  @override
  ConsumerState<WorkspaceGrid> createState() => _WorkspaceGridState();
}

class _WorkspaceGridState extends ConsumerState<WorkspaceGrid> {
  // Divider drag state.
  String? _dragDividerId;
  double _dragStartRatio = 0.5;
  double _dividerDragOffset = 0;
  // PowerPoint-style snap feedback for the active divider drag.
  String? _snapLabel;
  double? _dragRatio;

  // Leaf drag (swap) state, edit mode only.
  String? _dragLeafId;
  String? _swapTargetId;
  Offset _dragPointer = Offset.zero;

  // Layout memo: the tree only changes on mutations, not on telemetry ticks.
  LayoutNode? _layoutForRoot;
  Size? _layoutForSize;
  LayoutResult? _layoutCache;

  LayoutResult _layoutCached(LayoutNode root, Size size) {
    if (identical(root, _layoutForRoot) && size == _layoutForSize) {
      return _layoutCache!;
    }
    final result = layoutTree(root, Rect2(0, 0, size.width, size.height),
        TileRegistry.minSizeOf);
    _layoutForRoot = root;
    _layoutForSize = size;
    _layoutCache = result;
    updateKnownRects(result);
    return result;
  }

  // Last laid-out grid size (inside the outer padding) — used for
  // edit-mode hit testing so it matches the rects the renderer produced.
  Size? _lastLayoutSize;

  @override
  Widget build(BuildContext context) {
    final workspace = ref.watch(workspaceProvider).value?.active;

    if (workspace == null) {
      return const Center(child: CircularProgressIndicator());
    }
    final root = workspace.root;
    if (root == null) {
      return _EmptyWorkspace(
        onAddTile: () => showTilePicker(context, ref),
      );
    }

    // Outer padding so tiles never touch the window edge.
    return Padding(
      padding: const EdgeInsets.all(AppDimens.outerPadding),
      child: LayoutBuilder(builder: (context, constraints) {
        final size = Size(constraints.maxWidth, constraints.maxHeight);
        _lastLayoutSize = size;
        final result = _layoutCached(root, size);

        return Stack(
          clipBehavior: Clip.hardEdge,
          children: [
            for (final entry in result.leafRects.entries)
              if (TileRegistry.byId(_typeOf(workspace, entry.key)) != null)
                _buildLeaf(
                  workspace: workspace,
                  tileId: entry.key,
                  rect: entry.value,
                  swapTarget: _swapTargetId == entry.key,
                ),
            for (final divider in result.dividers)
              _buildDivider(divider, result.dividers),
            if (_dragDividerId != null)
              _buildSnapOverlay(result, size),
            if (_dragLeafId != null)
              Positioned(
                left: _dragPointer.dx,
                top: _dragPointer.dy,
              child: IgnorePointer(
                child: _DragBadge(),
              ),
              ),
          ],
        );
      }),
    );
  }

  String _typeOf(Workspace ws, String tileId) =>
      ws.leafOf(tileId)?.tileType ?? '';

  // ── Leaves ──────────────────────────────────────────────────────────────────

  Widget _buildLeaf({
    required Workspace workspace,
    required String tileId,
    required Rect2 rect,
    required bool swapTarget,
  }) {
    final tileType = _typeOf(workspace, tileId);
    final descriptor = TileRegistry.byId(tileType);
    if (descriptor == null) return const SizedBox.shrink();

    final isDragged = _dragLeafId == tileId;

    Widget card = AppCard(
      fillChild: true,
      title: descriptor.title,
      borderColor: isDragged || swapTarget ? AppColors.primary : null,
      // Immersive tiles (map, 3D) render edge-to-edge under the header.
      padding: descriptor.immersive ? EdgeInsets.zero : null,
      trailing: widget.editMode
          ? _EditHeaderActions(
              tileId: tileId,
              tileWidth: rect.width,
              swapTarget: swapTarget,
            )
          : null,
      child: widget.editMode
          // Block tile interactivity while layout handles are active.
          ? AbsorbPointer(child: descriptor.builder(context))
          : descriptor.builder(context),
    );

    if (widget.editMode) {
      card = GestureDetector(
        behavior: HitTestBehavior.opaque,
        onPanStart: (details) {
          setState(() {
            _dragLeafId = tileId;
            _dragPointer = Offset(rect.left + details.localPosition.dx,
                rect.top + details.localPosition.dy);
            _swapTargetId = null;
          });
        },
        onPanUpdate: (details) {
          _dragPointer += details.delta;
          final target = _leafAt(_dragPointer, tileId);
          if (target != _swapTargetId) {
            setState(() => _swapTargetId = target);
          }
        },
        onPanEnd: (_) {
          final target = _swapTargetId;
          if (target != null) {
            ref
                .read(workspaceProvider.notifier)
                .swapTiles(tileId: tileId, ontoTileId: target);
          }
          setState(() {
            _dragLeafId = null;
            _swapTargetId = null;
          });
        },
        child: card,
      );
    }

    return Positioned(
      left: rect.left,
      top: rect.top,
      width: rect.width,
      height: rect.height,
      child: card,
    );
  }

  /// Finds the leaf whose rect contains [position], excluding [excludeId].
  String? _leafAt(Offset position, String excludeId) {
    final workspace = ref.read(workspaceProvider).value?.active;
    final root = workspace?.root;
    if (root == null) return null;
    final size = _lastLayoutSize;
    if (size == null) return null;
    final result = _layoutCached(root, size);
    for (final entry in result.leafRects.entries) {
      if (entry.key == excludeId) continue;
      final r = entry.value;
      if (position.dx >= r.left &&
          position.dx <= r.left + r.width &&
          position.dy >= r.top &&
          position.dy <= r.top + r.height) {
        return entry.key;
      }
    }
    return null;
  }

  // ── Dividers ────────────────────────────────────────────────────────────────

  Widget _buildDivider(DividerHandle divider, List<DividerHandle> all) {
    // Dividers are only visible (and draggable) in layout-edit mode; outside
    // it the cards' own borders already separate the tiles. They stay
    // Positioned in both modes so the Stack's child shape never changes.
    if (!widget.editMode) {
      return Positioned(
        left: divider.hitArea.left,
        top: divider.hitArea.top,
        width: divider.hitArea.width,
        height: divider.hitArea.height,
        child: const SizedBox.shrink(),
      );
    }

    final isDragging = _dragDividerId == divider.nodeId;
    final snapped = isDragging && _snapLabel != null;
    final thickness = snapped ? 4.0 : (isDragging ? 3.0 : 1.0);
    final lineColor =
        isDragging ? AppColors.primary : AppColors.strongBorder;

    // Wider hit area than the visible line.
    const hit = 10.0;
    final positioned = Positioned(
      left: divider.hitArea.left - (divider.vertical ? 0 : (hit - dividerWidth) / 2),
      top: divider.hitArea.top - (divider.vertical ? (hit - dividerWidth) / 2 : 0),
      width: divider.vertical ? divider.hitArea.width : hit,
      height: divider.vertical ? hit : divider.hitArea.height,
        child: MouseRegion(
          cursor: divider.vertical
              ? SystemMouseCursors.resizeRow
              : SystemMouseCursors.resizeColumn,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            // Double-click flips the split between horizontal and vertical.
            onDoubleTap: () => ref
                .read(workspaceProvider.notifier)
                .toggleSplitOrientation(nodeId: divider.nodeId),
            onPanStart: (_) {
              setState(() {
                _dragDividerId = divider.nodeId;
                _dragStartRatio = divider.ratio;
                _dividerDragOffset = 0;
                _snapLabel = null;
                _dragRatio = divider.ratio;
              });
            },
            onPanUpdate: (details) {
              _dividerDragOffset +=
                  divider.vertical ? details.delta.dy : details.delta.dx;
              final raw = (_dragStartRatio +
                      _dividerDragOffset / divider.extent)
                  .clamp(0.02, 0.98);
              // PowerPoint-style snapping: align with sibling dividers or
              // land on 25/33/50/66/75% when close.
              final snap = snapDividerRatio(
                rawRatio: raw,
                dragged: divider,
                all: _layoutCache?.dividers ?? all,
              );
              final ratio = (snap?.ratio ?? raw).clamp(0.02, 0.98);
              setState(() {
                _snapLabel = snap?.label;
                _dragRatio = ratio;
              });
              ref.read(workspaceProvider.notifier).setRatio(
                    nodeId: divider.nodeId,
                    ratio: ratio,
                    persist: false,
                  );
            },
            onPanEnd: (_) {
              setState(() {
                _dragDividerId = null;
                _snapLabel = null;
                _dragRatio = null;
              });
              ref.read(workspaceProvider.notifier).persistActive();
            },
            child: Tooltip(
              message: 'Double-click to rotate',
              child: Center(
                child: divider.vertical
                    ? Container(height: thickness, color: lineColor)
                    : Container(width: thickness, color: lineColor),
              ),
            ),
          ),
        ),
    );
    return positioned;
  }

  /// PowerPoint-style feedback while a divider drags: a full-span dashed
  /// guide when aligned with a neighbour plus a small badge with the live
  /// percentage / snap label at the divider midpoint.
  Widget _buildSnapOverlay(LayoutResult result, Size gridSize) {
    final id = _dragDividerId;
    if (id == null) return const SizedBox.shrink();
    DividerHandle? dragged;
    for (final d in result.dividers) {
      if (d.nodeId == id) {
        dragged = d;
        break;
      }
    }
    if (dragged == null) return const SizedBox.shrink();
    final d = dragged;
    final ratio = _dragRatio ?? d.ratio;
    final pct = (ratio * 100).round();
    final label = _snapLabel == null ? '$pct%' : '$pct% · $_snapLabel';

    // Midpoint of the divider for the badge.
    final midX = d.vertical
        ? d.hitArea.left + d.hitArea.width / 2
        : d.hitArea.left;
    final midY = d.vertical
        ? d.hitArea.top
        : d.hitArea.top + d.hitArea.height / 2;

    final isAligned = _snapLabel == 'Aligned';
    return Stack(
      children: [
        // Full-span smart guide (PowerPoint-style) on alignment snaps.
        // `vertical` means the children are stacked top/bottom, so the
        // divider itself is horizontal and the guide must be too (and
        // vice versa for side-by-side splits).
        if (isAligned)
          if (d.vertical)
            Positioned(
              left: 0,
              top: midY - 0.5,
              width: gridSize.width,
              height: 1,
              child: IgnorePointer(
                child: Container(color: AppColors.primary.withValues(alpha: 0.55)),
              ),
            )
          else
            Positioned(
              left: midX - 0.5,
              top: 0,
              width: 1,
              height: gridSize.height,
              child: IgnorePointer(
                child: Container(color: AppColors.primary.withValues(alpha: 0.55)),
              ),
            ),
        Positioned(
          left: (d.vertical ? midX + 10 : midX - 20).clamp(
              0.0, (gridSize.width - 90).clamp(0.0, double.infinity)),
          top: (d.vertical ? midY - 34 : midY + 10).clamp(
              0.0, (gridSize.height - 30).clamp(0.0, double.infinity)),
          child: IgnorePointer(
            child: Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.85),
                borderRadius: BorderRadius.circular(6),
                border: Border.all(
                  color: _snapLabel == null
                      ? Colors.white24
                      : AppColors.primary,
                ),
              ),
              child: Text(
                label,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 11,
                  fontFeatures: [],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// Small badge that follows the pointer while dragging a tile in edit mode.
class _DragBadge extends StatelessWidget {
  const _DragBadge();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: AppColors.primary,
        borderRadius: BorderRadius.circular(6),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.2),
            blurRadius: 6,
          ),
        ],
      ),
      child: Icon(
        Icons.swap_horiz,
        size: 14,
        color: AppColors.primaryForeground,
      ),
    );
  }
}

/// Edit-mode header actions: no drag handle (the whole card drags), an
/// in-place type switcher plus split/remove. Narrow tiles collapse all
/// three into a `...` menu so the header can never overflow.
class _EditHeaderActions extends ConsumerWidget {
  final String tileId;
  final double tileWidth;
  final bool swapTarget;

  const _EditHeaderActions({
    required this.tileId,
    required this.tileWidth,
    required this.swapTarget,
  });

  static const double _collapseBelow = 360;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final notifier = ref.read(workspaceProvider.notifier);
    void change() => showTilePicker(context, ref, changeTileId: tileId);
    void split() => showTilePicker(context, ref, splitTileId: tileId);
    void remove() => notifier.removeTile(tileId);

    if (swapTarget || tileWidth < _collapseBelow) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (swapTarget)
            Padding(
              padding: const EdgeInsets.only(right: 2),
              child: Icon(
                Icons.swap_horiz,
                size: 16,
                color: AppColors.primary,
              ),
            ),
          PopupMenuButton<String>(
            tooltip: 'Tile actions',
            icon: Icon(
              Icons.more_horiz,
              size: 16,
              color: AppColors.mutedForeground,
            ),
            padding: EdgeInsets.zero,
            onSelected: (value) {
              switch (value) {
                case 'change':
                  change();
                case 'split':
                  split();
                case 'remove':
                  remove();
              }
            },
            itemBuilder: (context) => const [
              PopupMenuItem(
                value: 'change',
                child: Row(
                  children: [
                    Icon(Icons.swap_horiz, size: 16),
                    SizedBox(width: 8),
                    Text('Change type…'),
                  ],
                ),
              ),
              PopupMenuItem(
                value: 'split',
                child: Row(
                  children: [
                    Icon(Icons.splitscreen, size: 16),
                    SizedBox(width: 8),
                    Text('Split…'),
                  ],
                ),
              ),
              PopupMenuItem(
                value: 'remove',
                child: Row(
                  children: [
                    Icon(Icons.delete_outline, size: 16),
                    SizedBox(width: 8),
                    Text('Remove'),
                  ],
                ),
              ),
            ],
          ),
        ],
      );
    }

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _HeaderIconButton(
          icon: Icons.swap_horiz,
          tooltip: 'Change tile type',
          onTap: change,
        ),
        const SizedBox(width: 4),
        _HeaderIconButton(
          icon: Icons.splitscreen,
          tooltip: 'Split this tile in two and pick a tile',
          onTap: split,
        ),
        const SizedBox(width: 4),
        _HeaderIconButton(
          icon: Icons.delete_outline,
          tooltip: 'Remove this tile from the layout',
          danger: true,
          onTap: remove,
        ),
      ],
    );
  }
}

/// Compact icon-only header button (no text labels that overflow).
class _HeaderIconButton extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final bool danger;
  final VoidCallback onTap;

  const _HeaderIconButton({
    required this.icon,
    required this.tooltip,
    this.danger = false,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final color =
        danger ? AppColors.destructive : AppColors.mutedForeground;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: Tooltip(
        message: tooltip,
        child: Material(
          color: Colors.transparent,
          borderRadius: BorderRadius.circular(6),
          child: InkWell(
            onTap: onTap,
            mouseCursor: SystemMouseCursors.click,
            borderRadius: BorderRadius.circular(6),
            child: Container(
              padding: const EdgeInsets.all(4),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: AppColors.border),
              ),
              child: Icon(icon, size: 13, color: color),
            ),
          ),
        ),
      ),
    );
  }
}

class _EmptyWorkspace extends StatelessWidget {
  final VoidCallback onAddTile;

  const _EmptyWorkspace({required this.onAddTile});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.dashboard_customize_outlined,
              size: 40, color: AppColors.strongBorder),
          const SizedBox(height: 12),
          Text(
            'This workspace is empty',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 4),
          Text(
            'Tiles show live telemetry, charts and 3D views.',
            style: TextStyle(color: AppColors.mutedForeground),
          ),
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: onAddTile,
            icon: const Icon(Icons.add, size: 16),
            label: const Text('Add tile'),
          ),
        ],
      ),
    );
  }
}
