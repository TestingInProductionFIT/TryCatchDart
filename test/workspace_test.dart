import 'dart:ui' show Size;

import 'package:flutter_test/flutter_test.dart';
import 'package:trycatch/workspaces/layout_tree.dart';
import 'package:trycatch/workspaces/widget_registry.dart';
import 'package:trycatch/workspaces/workspace_models.dart';

Size _minOf(String typeId) => WidgetRegistry.minSizeOf(typeId);

LeafNode leaf(String typeId) =>
    LeafNode(widgetId: 'w_$typeId', typeId: typeId);

void main() {
  group('layout tree', () {
    test('treeFromOrder keeps every widget exactly once', () {
      final root = treeFromOrder(
          ['a', 'b', 'c', 'd', 'e'].map(leaf).toList());
      expect(root.leaves.map((l) => l.typeId), ['a', 'b', 'c', 'd', 'e']);
    });

    test('minSize combines children correctly per orientation', () {
      final minA = const Size(200, 120);
      final minB = const Size(240, 100);
      Size lookup(String id) => id == 'a' ? minA : minB;

      final horizontal = SplitNode(
        vertical: false,
        ratio: 0.5,
        a: leaf('a'),
        b: leaf('b'),
      );
      expect(horizontal.minSize(lookup).width, 200 + 240 + dividerWidth);
      expect(horizontal.minSize(lookup).height, 120);

      final vertical = SplitNode(vertical: true, ratio: 0.5, a: horizontal, b: leaf('b'));
      expect(vertical.minSize(lookup).width, horizontal.minSize(lookup).width);
      expect(vertical.minSize(lookup).height,
          120 + 100 + dividerWidth);
    });

    test('layoutTree fills the bounds and clamps ratios to minimums', () {
      // 200px minimum for the first child, 10px min width for everything.
      final root = SplitNode(
        vertical: false,
        ratio: 0.02, // would violate the 200px minimum
        a: leaf('map'),
        b: leaf('hall_sensor'),
      );

      final result = layoutTree(root, const Rect2(0, 0, 800, 300), _minOf);

      final a = result.leafRects['w_map']!;
      final b = result.leafRects['w_hall_sensor']!;
      expect(a.width, greaterThanOrEqualTo(WidgetRegistry.minSizeOf('map').width));
      expect(b.width,
          greaterThanOrEqualTo(WidgetRegistry.minSizeOf('hall_sensor').width));
      expect(a.left + a.width + dividerWidth, b.left);
      expect(result.dividers.length, 1);
    });

    test('insertLeaf splits the largest leaf', () {
      final tree = treeFromOrder([leaf('map'), leaf('stats')]);
      final result = insertLeaf(tree, 'fsm', 'new1', _minOf)!;

      final leaves = result.root.leaves;
      expect(leaves.length, 3);
      expect(leaves.where((l) => l.typeId == 'fsm').length, 1);
      expect(result.widgetId, 'new1');
    });

    test('removeLeaf collapses its split', () {
      final root = SplitNode(
        vertical: false,
        ratio: 0.5,
        a: leaf('map'),
        b: SplitNode(vertical: true, ratio: 0.5, a: leaf('stats'), b: leaf('fsm')),
      );

      final after = removeLeaf(root, 'w_stats');
      expect(after!.leaves.map((l) => l.typeId).toSet(), {'map', 'fsm'});
      expect(removeLeaf(root, 'w_map')!.leaves.length, 2);
    });

    test('swapLeaves exchanges content, not structure', () {
      final original = treeFromOrder([leaf('map'), leaf('stats')]);
      final swapped = swapLeaves(original, 'w_map', 'w_stats')!;

      expect(swapped.leaves.length, 2);
      final types = swapped.leaves.map((l) => l.typeId).toSet();
      expect(types, {'map', 'stats'});
      // The leaf positions changed: map now sits where stats was.
      expect(swapped.leaves.first.typeId, 'stats');
    });

    test('splitLeaf splits the named tile, not the largest one', () {
      final root = treeFromOrder([leaf('map'), leaf('stats')]);
      final result =
          splitLeaf(root, 'w_stats', 'flight_3d', 'w_new', _minOf)!;

      expect(result.widgetId, 'w_new');
      final types = result.root.leaves.map((l) => l.typeId).toSet();
      expect(types, {'map', 'stats', 'flight_3d'});

      // The new leaf sits next to stats inside the split that replaced it.
      final split = result.root as SplitNode;
      final subtreeTypes = <String>[
        ...split.a.leaves.map((l) => l.typeId),
        ...split.b.leaves.map((l) => l.typeId),
      ];
      expect(subtreeTypes, containsAll(['stats', 'flight_3d']));
    });

    test('splitLeaf returns null for an unknown widget id', () {
      final root = treeFromOrder([leaf('map'), leaf('stats')]);
      expect(splitLeaf(root, 'w_nope', 'stats', 'w_new', _minOf), isNull);
    });

    test('JSON round-trip preserves ids, ratios and leaves', () {
      final root = SplitNode(
        id: 'root1',
        vertical: true,
        ratio: 0.7,
        a: leaf('map'),
        b: leaf('fsm'),
      );

      final restored = LayoutNode.fromJson(root.toJson()) as SplitNode;
      expect(restored.id, 'root1');
      expect(restored.vertical, isTrue);
      expect(restored.ratio, 0.7);
      expect(restored.leaves.map((l) => l.typeId), ['map', 'fsm']);
    });

    test('migrates persisted grid layouts', () {
      final workspace = Workspace.fromJson({
        'id': 'ws1',
        'name': 'Flight view',
        'placements': [
          {'widgetId': 'a', 'typeId': 'map', 'x': 0, 'y': 0, 'w': 5, 'h': 6},
          {'widgetId': 'b', 'typeId': 'stats', 'x': 5, 'y': 0, 'w': 3, 'h': 4},
        ],
      });

      expect(workspace.root, isNotNull);
      expect(workspace.root!.leaves.map((l) => l.typeId).toList(),
          ['map', 'stats']);
    });
  });

  group('default layouts', () {
    test('use known widget types and lay out without empty leaves', () {
      for (final ws in [
        WidgetRegistry.defaultFlightLayout(),
        WidgetRegistry.defaultPrepLayout(),
      ]) {
        expect(ws.root, isNotNull);
        for (final l in ws.root!.leaves) {
          expect(WidgetRegistry.byId(l.typeId), isNotNull);
        }
        // Layout is computable at a realistic dashboard size.
        final result = layoutTree(
          ws.root!,
          const Rect2(0, 0, 1800, 1000),
          _minOf,
        );
        expect(result.leafRects.length, ws.root!.leaves.length);
      }
    });
  });
}
