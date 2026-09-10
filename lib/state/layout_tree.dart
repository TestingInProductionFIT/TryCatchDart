/// Workspace layout as a KD-tree — hyprland-style tiling.
///
/// Internal nodes split their rectangle horizontally (left|right) or
/// vertically (top/bottom) at a draggable [SplitNode.ratio]; leaves are
/// tiles. Split directions alternate with depth so new splits rotate
/// orientation, and every tile type declares a minimum pixel size that the
/// divider drag respects.
library;

import 'dart:math' as math;
import 'dart:ui' show Size;

import 'package:flutter/material.dart' show debugPrint;

/// Per-tile-type minimum size in logical pixels (from `TileRegistry`).
typedef MinSizeLookup = Size Function(String tileType);

// ── Model ────────────────────────────────────────────────────────────────────

sealed class LayoutNode {
  const LayoutNode();

  /// All tile ids in this subtree, in layout order.
  List<LeafNode> get leaves;

  /// Minimum size this subtree can be squeezed to, in logical pixels.
  Size minSize(MinSizeLookup minOf);

  Map<String, dynamic> toJson();

  static LayoutNode fromJson(Map<String, dynamic> json) {
    final type = json['type'] as String;
    return switch (type) {
      'split' => SplitNode(
          id: json['id'] as String?,
          vertical: json['vertical'] as bool? ?? false,
          ratio: (json['ratio'] as num?)?.toDouble() ?? 0.5,
          a: LayoutNode.fromJson(json['a'] as Map<String, dynamic>),
          b: LayoutNode.fromJson(json['b'] as Map<String, dynamic>),
        ),
      'leaf' => LeafNode(
          tileId: json['tileId'] as String,
          tileType: json['tileType'] as String,
        ),
      _ => throw FormatException('Unknown layout node type: $type'),
    };
  }
}

/// Internal node: divides the available rect into two children.
class SplitNode extends LayoutNode {
  /// Stable identity for ratio updates across immutable tree rebuilds.
  final String id;

  /// `true` → children stacked top/bottom; `false` → side by side.
  final bool vertical;

  /// Fraction of the extent given to the first child (0..1).
  final double ratio;

  final LayoutNode a;
  final LayoutNode b;

  SplitNode({
    required this.vertical,
    required this.ratio,
    required this.a,
    required this.b,
    String? id,
  }) : id = id ?? _nextSplitId();

  /// Rebuilds this node with a new ratio (divider drag).
  SplitNode withRatio(double newRatio) => SplitNode(
        id: id,
        vertical: vertical,
        ratio: newRatio,
        a: a,
        b: b,
      );

  SplitNode withChildren({LayoutNode? a, LayoutNode? b}) => SplitNode(
        id: id,
        vertical: vertical,
        ratio: ratio,
        a: a ?? this.a,
        b: b ?? this.b,
      );

  /// Rebuilds this node with the split running along the other axis. The
  /// ratio carries over (it is a fraction of the new extent).
  SplitNode flipOrientation() => SplitNode(
        id: id,
        vertical: !vertical,
        ratio: ratio,
        a: a,
        b: b,
      );

  @override
  List<LeafNode> get leaves => [...a.leaves, ...b.leaves];

  @override
  Size minSize(MinSizeLookup minOf) {
    final sa = a.minSize(minOf);
    final sb = b.minSize(minOf);
    return vertical
        ? Size(
            math.max(sa.width, sb.width), sa.height + sb.height + dividerWidth)
        : Size(
            sa.width + sb.width + dividerWidth, math.max(sa.height, sb.height));
  }

  @override
  Map<String, dynamic> toJson() => {
        'type': 'split',
        'id': id,
        'vertical': vertical,
        'ratio': ratio,
        'a': a.toJson(),
        'b': b.toJson(),
      };
}

int _splitIdCounter = 0;

String _nextSplitId() => 's${_splitIdCounter++}';

/// Leaf: one tile instance.
class LeafNode extends LayoutNode {
  final String tileId;
  final String tileType;

  LeafNode({required this.tileId, required this.tileType});

  @override
  List<LeafNode> get leaves => [this];

  @override
  Size minSize(MinSizeLookup minOf) => minOf(tileType);

  @override
  Map<String, dynamic> toJson() =>
      {'type': 'leaf', 'tileId': tileId, 'tileType': tileType};
}

/// Visual thickness of the divider between split children.
const double dividerWidth = 8;

// ── Geometry ─────────────────────────────────────────────────────────────────

/// A rectangle in logical pixels.
class Rect2 {
  final double left, top, width, height;

  const Rect2(this.left, this.top, this.width, this.height);
}

/// Result of laying the tree out: leaf → its rect, plus every divider that
/// can be dragged.
class LayoutResult {
  final Map<String, Rect2> leafRects;
  final List<DividerHandle> dividers;

  const LayoutResult({required this.leafRects, required this.dividers});
}

/// A draggable divider between two subtrees.
class DividerHandle {
  final String nodeId;
  final Rect2 hitArea;

  /// Orientation of the split the divider belongs to.
  final bool vertical;

  /// Full extent (px) available to the two children along the split axis.
  final double extent;

  /// The clamped ratio actually used for this layout (for drag deltas).
  final double ratio;

  const DividerHandle({
    required this.nodeId,
    required this.hitArea,
    required this.vertical,
    required this.extent,
    required this.ratio,
  });
}

/// Lays out the tree inside [bounds], clamping ratios so both sides of every
/// split keep their minimum sizes.
LayoutResult layoutTree(
  LayoutNode root,
  Rect2 bounds,
  MinSizeLookup minOf,
) {
  final leafRects = <String, Rect2>{};
  final dividers = <DividerHandle>[];
  _layoutNode(root, bounds, minOf, leafRects, dividers);
  return LayoutResult(leafRects: leafRects, dividers: dividers);
}

void _layoutNode(
  LayoutNode node,
  Rect2 bounds,
  MinSizeLookup minOf,
  Map<String, Rect2> leafRects,
  List<DividerHandle> dividers,
) {
  if (node is LeafNode) {
    leafRects[node.tileId] = bounds;
    return;
  }
  if (node is! SplitNode) return;

  final minA = node.a.minSize(minOf);
  final minB = node.b.minSize(minOf);

  final extent = node.vertical ? bounds.height : bounds.width;
  final minAExtent = node.vertical ? minA.height : minA.width;
  final minBExtent = node.vertical ? minB.height : minB.width;

  final usable = (extent - dividerWidth).clamp(0.0, double.infinity);
  final ratio = _clampRatio(node.ratio, usable, minAExtent, minBExtent);

  final firstExtent = ratio * usable;
  final secondExtent = usable - firstExtent;

  final dividerHit = node.vertical
      ? Rect2(bounds.left, bounds.top + firstExtent, bounds.width, dividerWidth)
      : Rect2(bounds.left + firstExtent, bounds.top, dividerWidth, bounds.height);

  dividers.add(DividerHandle(
    nodeId: node.id,
    hitArea: dividerHit,
    vertical: node.vertical,
    extent: usable,
    ratio: ratio,
  ));

  if (node.vertical) {
    _layoutNode(node.a,
        Rect2(bounds.left, bounds.top, bounds.width, firstExtent), minOf,
        leafRects, dividers);
    _layoutNode(node.b,
        Rect2(bounds.left, bounds.top + firstExtent + dividerWidth, bounds.width, secondExtent),
        minOf, leafRects, dividers);
  } else {
    _layoutNode(node.a,
        Rect2(bounds.left, bounds.top, firstExtent, bounds.height), minOf,
        leafRects, dividers);
    _layoutNode(node.b,
        Rect2(bounds.left + firstExtent + dividerWidth, bounds.top, secondExtent, bounds.height),
        minOf, leafRects, dividers);
  }
}

/// Clamps [ratio] so both children keep their minimum extents.
double _clampRatio(
  double ratio,
  double usable,
  double minFirst,
  double minSecond,
) {
  if (usable <= 0) return 0.5;
  final lo = minFirst / usable;
  final hi = 1 - minSecond / usable;
  if (lo > hi) return 0.5; // children can't both fit — center the divider
  return ratio.clamp(lo, hi);
}

// ── Mutations (pure) ─────────────────────────────────────────────────────────

/// Inserts a new leaf for [tileType] by splitting the largest-area leaf.
///
/// The split orientation is chosen from the target leaf's shape (wide leaf →
/// side-by-side, tall leaf → stacked), keeping the tiling balanced.
({LayoutNode root, String tileId})? insertLeaf(
  LayoutNode? root,
  String tileType,
  String newTileId,
  MinSizeLookup minOf,
) {
  if (root == null) {
    return (root: LeafNode(tileId: newTileId, tileType: tileType), tileId: newTileId);
  }

  // Find the largest-area leaf and its parent path.
  final leavesWithRects = <(LeafNode, double)>[];
  _collectAreas(root, boundsFor(root, minOf), minOf, leavesWithRects);
  if (leavesWithRects.isEmpty) return null;

  leavesWithRects.sort((x, y) => y.$2.compareTo(x.$2));
  final target = leavesWithRects.first.$1;

  final newLeaf = LeafNode(tileId: newTileId, tileType: tileType);
  final result = _splitLeaf(root, target.tileId, newLeaf, minOf);
  return (root: result, tileId: newTileId);
}

/// Splits the leaf [tileId] into two, placing [newTileId] with [tileType]
/// beside it. Returns `null` when [tileId] is not in the tree.
({LayoutNode root, String tileId})? splitLeaf(
  LayoutNode? root,
  String tileId,
  String tileType,
  String newTileId,
  MinSizeLookup minOf,
) {
  if (root == null) return null;
  if (!root.leaves.any((l) => l.tileId == tileId)) return null;
  final newLeaf = LeafNode(tileId: newTileId, tileType: tileType);
  return (
    root: _splitLeaf(root, tileId, newLeaf, minOf),
    tileId: newTileId,
  );
}

/// Rough reference bounds used only to rank leaves by area.
Rect2 boundsFor(LayoutNode root, MinSizeLookup minOf) {
  final min = root.minSize(minOf);
  // Give the tree lots of room so relative proportions decide "largest".
  return Rect2(0, 0, math.max(min.width, 1200), math.max(min.height, 800));
}

void _collectAreas(
  LayoutNode node,
  Rect2 bounds,
  MinSizeLookup minOf,
  List<(LeafNode, double)> out,
) {
  if (node is LeafNode) {
    out.add((node, bounds.width * bounds.height));
    return;
  }
  if (node is! SplitNode) return;

  final minA = node.a.minSize(minOf);
  final minB = node.b.minSize(minOf);
  final extent = node.vertical ? bounds.height : bounds.width;
  final minAExtent = node.vertical ? minA.height : minA.width;
  final minBExtent = node.vertical ? minB.height : minB.width;
  final usable = (extent - dividerWidth).clamp(0.0, double.infinity);
  final ratio = _clampRatio(node.ratio, usable, minAExtent, minBExtent);
  final firstExtent = ratio * usable;
  final secondExtent = usable - firstExtent;

  if (node.vertical) {
    _collectAreas(node.a, Rect2(bounds.left, bounds.top, bounds.width, firstExtent), minOf, out);
    _collectAreas(node.b, Rect2(bounds.left, bounds.top + firstExtent + dividerWidth, bounds.width, secondExtent), minOf, out);
  } else {
    _collectAreas(node.a, Rect2(bounds.left, bounds.top, firstExtent, bounds.height), minOf, out);
    _collectAreas(node.b, Rect2(bounds.left + firstExtent + dividerWidth, bounds.top, secondExtent, bounds.height), minOf, out);
  }
}

/// Replaces the leaf with [tileId] by a split containing it and [newLeaf].
LayoutNode _splitLeaf(
  LayoutNode node,
  String tileId,
  LeafNode newLeaf,
  MinSizeLookup minOf,
) {
  if (node is LeafNode) {
    if (node.tileId != tileId) return node;
    // Alternate orientation based on shape: wide → side-by-side.
    final rect = _lastKnownRects[tileId];
    final vertical = rect != null ? rect.height > rect.width : false;
    return SplitNode(vertical: vertical, ratio: 0.5, a: node, b: newLeaf);
  }
  if (node is SplitNode) {
    return node.withChildren(
      a: _splitLeaf(node.a, tileId, newLeaf, minOf),
      b: _splitLeaf(node.b, tileId, newLeaf, minOf),
    );
  }
  return node;
}

/// Remembered rects from the last real layout, used to pick split orientation
/// when inserting. Cleared/re-filled by the renderer each frame.
final Map<String, Rect2> _lastKnownRects = {};

/// Call from the renderer so insertions can pick a sensible split direction.
void updateKnownRects(LayoutResult result) {
  _lastKnownRects
    ..clear()
    ..addAll(result.leafRects);
}

/// Removes the leaf with [tileId]; a parent split with a single remaining
/// child collapses into that child.
LayoutNode? removeLeaf(LayoutNode? root, String tileId) {
  if (root == null) return null;
  if (root is LeafNode) {
    return root.tileId == tileId ? null : root;
  }
  if (root is! SplitNode) return null;

  final newA = removeLeaf(root.a, tileId);
  final newB = removeLeaf(root.b, tileId);

  if (newA == null) return newB;
  if (newB == null) return newA;
  return root.withChildren(a: newA, b: newB);
}

/// Swaps the *content* of two leaves (drag a tile onto another).
LayoutNode? swapLeaves(LayoutNode? root, String tileId, String otherId) {
  if (root == null || tileId == otherId) return root;

  LeafNode? first;
  LeafNode? second;
  void collect(LayoutNode node) {
    if (node is LeafNode) {
      if (node.tileId == tileId) first = node;
      if (node.tileId == otherId) second = node;
    } else if (node is SplitNode) {
      collect(node.a);
      collect(node.b);
    }
  }

  collect(root);
  if (first == null || second == null) return root;
  final source = second!;
  final target = first!;

  LayoutNode replace(LayoutNode node) {
    if (node is LeafNode) {
      if (node.tileId == tileId) {
        return LeafNode(tileId: source.tileId, tileType: source.tileType);
      }
      if (node.tileId == otherId) {
        return LeafNode(tileId: target.tileId, tileType: target.tileType);
      }
      return node;
    }
    if (node is SplitNode) {
      return node.withChildren(a: replace(node.a), b: replace(node.b));
    }
    return node;
  }

  return replace(root);
}

// ── Factory ──────────────────────────────────────────────────────────────────

/// Builds a balanced alternating tree from an ordered tile list — used as
/// the factory default layout.
LayoutNode treeFromOrder(List<LeafNode> leaves) {
  LayoutNode build(List<LeafNode> list, int depth) {
    if (list.length == 1) return list.single;
    final mid = (list.length / 2).ceil();
    // Alternate: even depth → side-by-side, odd depth → stacked.
    final vertical = depth.isOdd;
    return SplitNode(
      vertical: vertical,
      ratio: 0.5,
      a: build(list.sublist(0, mid), depth + 1),
      b: build(list.sublist(mid), depth + 1),
    );
  }

  if (leaves.isEmpty) {
    debugPrint('layout_tree: building tree from empty list');
  }
  return build(leaves, 0);
}
