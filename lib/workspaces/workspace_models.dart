import 'layout_tree.dart';

/// A named workspace: an independent widget arrangement (a layout tree).
class Workspace {
  final String id;
  final String name;

  /// Root of the layout tree; `null` while the workspace is empty.
  final LayoutNode? root;

  const Workspace({
    required this.id,
    required this.name,
    required this.root,
  });

  Workspace copyWith({String? name, LayoutNode? root}) => Workspace(
        id: id,
        name: name ?? this.name,
        root: root ?? this.root,
      );

  /// The widget leaf with [widgetId], or `null`.
  LeafNode? leafOf(String widgetId) {
    for (final leaf in root?.leaves ?? const <LeafNode>[]) {
      if (leaf.widgetId == widgetId) return leaf;
    }
    return null;
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'root': root?.toJson(),
      };

  factory Workspace.fromJson(Map<String, dynamic> json) {
    final rootJson = json['root'];
    LayoutNode? root = rootJson == null
        ? null
        : LayoutNode.fromJson(rootJson as Map<String, dynamic>);

    // Migration from the old grid representation: derive the widget order
    // from stored coordinates, then build a balanced alternating tree.
    if (root == null && json['placements'] is List) {
      final placements = (json['placements'] as List)
          .whereType<Map<String, dynamic>>()
          .toList()
        ..sort((a, b) {
          final ay = (a['y'] as num?)?.toInt() ?? 0;
          final by = (b['y'] as num?)?.toInt() ?? 0;
          if (ay != by) return ay.compareTo(by);
          return ((a['x'] as num?)?.toInt() ?? 0)
              .compareTo((b['x'] as num?)?.toInt() ?? 0);
        });
      root = treeFromOrder([
        for (final p in placements)
          if (p['widgetId'] is String && p['typeId'] is String)
            LeafNode(
                widgetId: p['widgetId'] as String, typeId: p['typeId'] as String),
      ]);
    }

    return Workspace(
      id: json['id'] as String,
      name: json['name'] as String,
      root: root,
    );
  }
}

/// Monotonic id generator (no external dependency).
class GridIds {
  static int _counter = 0;

  static String next() {
    _counter++;
    return '${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}'
        '_${_counter.toRadixString(36)}';
  }
}
