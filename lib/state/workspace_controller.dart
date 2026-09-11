import 'dart:convert';
import 'dart:io' show Directory, File, Platform;

import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import './default_layouts.dart';
import './layout_tree.dart';
import './tile_registry.dart';
import './workspace_models.dart';
import '../services/prefs_keys.dart';

/// All workspaces + which one is active.
class WorkspaceState {
  final List<Workspace> workspaces;
  final String activeId;

  const WorkspaceState({required this.workspaces, required this.activeId});

  Workspace? get active {
    for (final w in workspaces) {
      if (w.id == activeId) return w;
    }
    return workspaces.isEmpty ? null : workspaces.first;
  }

  WorkspaceState copyWith({List<Workspace>? workspaces, String? activeId}) =>
      WorkspaceState(
        workspaces: workspaces ?? this.workspaces,
        activeId: activeId ?? this.activeId,
      );

  Map<String, dynamic> toJson() => {
        'activeId': activeId,
        'workspaces': workspaces.map((w) => w.toJson()).toList(),
      };

  factory WorkspaceState.fromJson(Map<String, dynamic> json) {
    final workspaces = (json['workspaces'] as List<dynamic>? ?? [])
        .map((e) => Workspace.fromJson(e as Map<String, dynamic>))
        .toList();
    // No heuristics: the app always shows the first layout (on start,
    // after replay, etc.). The persisted activeId is intentionally ignored.
    return WorkspaceState(
      workspaces: workspaces,
      activeId: workspaces.isEmpty ? '' : workspaces.first.id,
    );
  }
}

/// Persisted workspace CRUD + layout-tree mutations.
///
/// All tree operations are pure functions in `layout_tree.dart`; this store
/// only coordinates state and persistence.
final workspaceProvider =
    AsyncNotifierProvider<WorkspaceStore, WorkspaceState>(WorkspaceStore.new);

class WorkspaceStore extends AsyncNotifier<WorkspaceState> {
  static const String _prefsKey = PrefsKeys.workspaces;

  MinSizeLookup get _minOf => (tileType) => TileRegistry.minSizeOf(tileType);

  @override
  Future<WorkspaceState> build() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_prefsKey);
      if (raw != null) {
        final loaded =
            WorkspaceState.fromJson(jsonDecode(raw) as Map<String, dynamic>);
        if (loaded.workspaces.isNotEmpty) {
          return _healed(loaded);
        }
      }
    } catch (_) {
      // Corrupt persistence falls through to defaults.
    }
    return _defaultState();
  }

  /// Reassigns duplicate split ids left over from installs that used a
  /// restart-resetting counter (they made one divider drag move several
  /// tiles at once). Pure + cheap; runs once per load.
  WorkspaceState _healed(WorkspaceState s) {
    var changed = false;
    final workspaces = [
      for (final w in s.workspaces)
        () {
          final fixed = ensureUniqueSplitIds(w.root);
          if (!identical(fixed, w.root)) {
            changed = true;
            return w.copyWith(root: fixed);
          }
          return w;
        }(),
    ];
    if (!changed) return s;
    final next = s.copyWith(workspaces: workspaces);
    // Heal persistence in the background; the in-memory state is already fixed.
    Future(() async {
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(_prefsKey, jsonEncode(next.toJson()));
      } catch (_) {}
    });
    return next;
  }

  WorkspaceState _defaultState() {
    final workspaces = DefaultLayouts.all();
    return WorkspaceState(
      workspaces: workspaces,
      activeId: workspaces.isEmpty ? '' : workspaces.first.id,
    );
  }

  Future<void> _persist(WorkspaceState next) async {
    state = AsyncData(next);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_prefsKey, jsonEncode(next.toJson()));
    } catch (_) {
      // Non-fatal; keep working from memory.
    }
  }

  /// Applies [update] to the active workspace. With [persist] the result is
  /// also written to disk — divider drags pass `false` while interacting and
  /// persist once on release.
  Future<void> _updateActive(
    Workspace Function(Workspace) update, {
    bool persist = true,
  }) async {
    final current = state.value;
    if (current == null) return;
    final active = current.active;
    if (active == null) return;

    final next = current.copyWith(
      workspaces: [
        for (final w in current.workspaces) w.id == active.id ? update(w) : w,
      ],
    );
    if (persist) {
      await _persist(next);
    } else {
      state = AsyncData(next);
    }
  }

  // ── Workspace CRUD ──────────────────────────────────────────────────────────

  Future<void> setActive(String id) async {
    final current = state.value;
    if (current == null) return;
    if (!current.workspaces.any((w) => w.id == id)) return;
    await _persist(current.copyWith(activeId: id));
  }

  Future<void> createWorkspace(String name) async {
    final current = state.value;
    if (current == null) return;
    final unique = _uniqueName(current.workspaces, name);
    final ws = Workspace(id: GridIds.next(), name: unique, root: null);
    await _persist(current.copyWith(
      workspaces: [...current.workspaces, ws],
      activeId: ws.id,
    ));
  }

  Future<void> duplicateWorkspace(String id) async {
    final current = state.value;
    if (current == null) return;
    final source = current.workspaces.where((w) => w.id == id).firstOrNull;
    if (source == null) return;
    final copy = Workspace(
      id: GridIds.next(),
      name: _uniqueName(current.workspaces, '${source.name} copy'),
      root: source.root,
    );
    await _persist(current.copyWith(
      workspaces: [...current.workspaces, copy],
      activeId: copy.id,
    ));
  }

  Future<void> renameWorkspace(String id, String name) async {
    final current = state.value;
    if (current == null) return;
    await _persist(current.copyWith(
      workspaces: [
        for (final w in current.workspaces) w.id == id ? w.copyWith(name: name) : w,
      ],
    ));
  }

  Future<void> deleteWorkspace(String id) async {
    final current = state.value;
    if (current == null || current.workspaces.length <= 1) return;
    final remaining = current.workspaces.where((w) => w.id != id).toList();
    await _persist(current.copyWith(
      workspaces: remaining,
      activeId: current.activeId == id ? remaining.first.id : current.activeId,
    ));
  }

  /// Moves the workspace with [id] to [newIndex] (final index after the
  /// move, clamped into range). No-op for unknown ids or a no-op move.
  Future<void> moveWorkspace(String id, int newIndex) async {
    final current = state.value;
    if (current == null) return;
    final oldIndex = current.workspaces.indexWhere((w) => w.id == id);
    if (oldIndex == -1) return;
    final clamped = newIndex.clamp(0, current.workspaces.length - 1);
    if (oldIndex == clamped) return;
    final reordered = [...current.workspaces];
    final ws = reordered.removeAt(oldIndex);
    reordered.insert(clamped, ws);
    await _persist(current.copyWith(workspaces: reordered));
  }

  /// Reorder entry point matching [ReorderableListView] semantics: [newIndex]
  /// is the insertion index in the list *with* the dragged item removed, so
  /// a forward move needs one step back.
  Future<void> reorderWorkspace(int oldIndex, int newIndex) async {
    final current = state.value;
    if (current == null) return;
    if (oldIndex < 0 || oldIndex >= current.workspaces.length) return;
    var target = newIndex.clamp(0, current.workspaces.length);
    if (oldIndex < target) target -= 1;
    await moveWorkspace(current.workspaces[oldIndex].id, target);
  }

  String _uniqueName(List<Workspace> existing, String base) {
    var name = base;
    var i = 2;
    while (existing.any((w) => w.name == name)) {
      name = '$base ${i++}';
    }
    return name;
  }

  // ── Layout tree mutations ───────────────────────────────────────────────────

  /// Adds a tile by splitting the largest leaf of the active workspace —
  /// or, with [splitTileId], by splitting that specific tile instead.
  Future<void> addTile(String tileType, {String? splitTileId}) async {
    await _updateActive((ws) {
      final result = splitTileId == null
          ? insertLeaf(ws.root, tileType, GridIds.next(), _minOf)
          : splitLeaf(ws.root, splitTileId, tileType, GridIds.next(), _minOf);
      return result == null ? ws : ws.copyWith(root: result.root);
    });
  }

  Future<void> removeTile(String tileId) async {
    await _updateActive((ws) {
      final next = removeLeaf(ws.root, tileId);
      return next == null ? ws.copyWith(clearRoot: true) : ws.copyWith(root: next);
    });
  }

  /// Replaces the tile type in place (keeps position + id).
  Future<void> changeTileType(String tileId, String newType) async {
    await _updateActive((ws) {
      final next = retileLeaf(ws.root, tileId, newType);
      return next == null ? ws : ws.copyWith(root: next);
    });
  }

  /// Swaps the content of two leaves (drag a tile onto another in edit mode).
  Future<void> swapTiles({
    required String tileId,
    required String ontoTileId,
    bool persist = true,
  }) async {
    await _updateActive(
      (ws) => ws.copyWith(
          root: swapLeaves(ws.root, tileId, ontoTileId)),
      persist: persist,
    );
  }

  /// Updates a split ratio (divider drag), located by stable node id.
  /// Only the first matching split moves, so duplicate ids from old
  /// installs can never drag two dividers at once.
  Future<void> setRatio({
    required String nodeId,
    required double ratio,
    bool persist = true,
  }) async {
    await _updateActive(
      (ws) => ws.copyWith(root: setSplitRatio(ws.root, nodeId, ratio)),
      persist: persist,
    );
  }

  /// Flips a split between horizontal and vertical (double-click on a
  /// divider in edit mode), located by stable node id.
  Future<void> toggleSplitOrientation({required String nodeId}) async {
    await _updateActive(
      (ws) => ws.copyWith(root: flipSplitOrientation(ws.root, nodeId)),
    );
  }

  /// Restores the active layout — called by undo after a merge.
  Future<void> restoreRoot(LayoutNode? savedRoot) async {
    await _updateActive(
      (ws) => savedRoot == null
          ? ws.copyWith(clearRoot: true)
          : ws.copyWith(root: savedRoot),
    );
  }

  /// Collapses the split [nodeId], keeping [keepSide] and discarding the other.
  Future<void> mergeDivider({
    required String nodeId,
    required KeepSide keepSide,
  }) async {
    await _updateActive((ws) {
      final root = ws.root;
      if (root == null) return ws;
      return ws.copyWith(root: mergeAtDivider(root, nodeId, keepSide));
    });
  }

  /// Inserts a new tile directly beside [targetId] in [direction] (from a
  /// split-arrow tap). Falls back to `insertLeaf` if the workspace is empty.
  Future<void> insertBesideTile({
    required String targetId,
    required SplitDirection direction,
    required String tileType,
  }) async {
    await _updateActive((ws) {
      final root = ws.root;
      if (root == null) {
        return ws.copyWith(
          root: LeafNode(tileId: GridIds.next(), tileType: tileType),
        );
      }
      return ws.copyWith(
        root: insertBesideLeaf(root, targetId, direction, tileType, GridIds.next()),
      );
    });
  }

  /// Restructure-drag: removes [sourceId] and re-inserts it beside [targetId].
  Future<void> moveTileBeside({
    required String sourceId,
    required String targetId,
    required SplitDirection direction,
  }) async {
    await _updateActive((ws) {
      final root = ws.root;
      if (root == null) return ws;
      return ws.copyWith(root: moveLeafBeside(root, sourceId, targetId, direction));
    });
  }

  /// Persists the current in-memory state — called at the end of drags whose
  /// updates were applied without persistence.
  Future<void> persistActive() async {
    final current = state.value;
    if (current != null) await _persist(current);
  }

  /// Restores the factory layouts, discarding all custom workspaces.
  Future<void> resetToDefaults() async => _persist(_defaultState());

  // ── Developer tools (debug only) ────────────────────────────────────────────

  /// Regenerates `lib/state/default_layouts.dart` from the current workspace
  /// state and writes it to disk. Only available in debug builds.
  ///
  /// Call this after arranging your workspaces exactly how you want the factory
  /// defaults to look. The file is overwritten in-place; reload the app
  /// (hot-restart) for `resetToDefaults()` to use the new values.
  Future<String?> promoteToDefaults() async {
    assert(kDebugMode, 'promoteToDefaults() must only be called in debug mode');
    final current = state.value;
    if (current == null) return 'No workspace state loaded.';

    final buf = StringBuffer();
    buf.writeln("import './layout_tree.dart';");
    buf.writeln("import './workspace_models.dart';");
    buf.writeln();
    buf.writeln('/// Factory default workspace arrangements.');
    buf.writeln('///');
    buf.writeln(
        '/// Auto-generated by WorkspaceStore.promoteToDefaults() — do not');
    buf.writeln('/// edit by hand. To update, arrange the workspaces in the');
    buf.writeln("/// app and use the 'Promote to defaults' developer button.");
    buf.writeln('abstract final class DefaultLayouts {');
    buf.writeln('  /// All factory default workspaces in order.');
    buf.writeln('  static List<Workspace> all() => [');
    final methodNames = <String>[];
    final usedNames = <String>{};
    for (var i = 0; i < current.workspaces.length; i++) {
      var name = _dartIdent(current.workspaces[i].name);
      if (usedNames.contains(name) || name == 'all') {
        name = '${name}_$i';
      }
      usedNames.add(name);
      methodNames.add(name);
      buf.writeln('        $name(),');
    }
    buf.writeln('      ];');

    for (var i = 0; i < current.workspaces.length; i++) {
      final ws = current.workspaces[i];
      final methodName = methodNames[i];
      buf.writeln();
      buf.writeln('  /// ${ws.name}');
      buf.writeln('  static Workspace $methodName() => Workspace(');
      buf.writeln('    id: GridIds.next(),');
      buf.writeln("    name: '${_escapeDart(ws.name)}',");
      if (ws.root == null) {
        buf.writeln('    root: null,');
      } else {
        buf.write('    root: ');
        _writeNode(buf, ws.root!, '    ');
        buf.writeln(',');
      }
      buf.writeln('  );');
    }

    buf.writeln('}');

    // Search directories: current working directory, script URI, and executable dir.
    final candidateDirs = <Directory>[
      Directory.current,
      File.fromUri(Platform.script).parent,
      File(Platform.resolvedExecutable).parent,
    ];

    for (final startDir in candidateDirs) {
      var dir = startDir;
      for (var i = 0; i < 10; i++) {
        final candidate = File('${dir.path}/lib/state/default_layouts.dart');
        if (candidate.existsSync()) {
          await candidate.writeAsString(buf.toString());
          return null; // success — null means no error
        }
        final pubspec = File('${dir.path}/pubspec.yaml');
        if (pubspec.existsSync()) {
          final candidate2 = File('${dir.path}/lib/state/default_layouts.dart');
          await candidate2.writeAsString(buf.toString());
          return null;
        }
        final parent = dir.parent;
        if (parent.path == dir.path) break;
        dir = parent;
      }
    }
    // Fallback: print to console so the developer can copy-paste.
    // ignore: avoid_print
    print('\n========== default_layouts.dart ==========\n$buf==========================================\n');
    return 'Could not locate project root — output printed to console.';
  }

  /// Converts a workspace name to a valid Dart method identifier.
  static String _dartIdent(String name) {
    // "Flight control" → "flightControl"
    final words = name
        .replaceAll(RegExp(r'[^a-zA-Z0-9 ]'), '')
        .trim()
        .split(RegExp(r'\s+'));
    if (words.isEmpty) return 'workspace';
    final first = words.first.toLowerCase();
    final rest = words.skip(1).map((w) {
      if (w.isEmpty) return '';
      return w[0].toUpperCase() + w.substring(1).toLowerCase();
    });
    return first + rest.join();
  }

  static String _escapeDart(String s) => s.replaceAll("'", "\\'");

  /// Recursively writes a [LayoutNode] as Dart constructor code.
  static void _writeNode(StringBuffer buf, dynamic node, String indent) {
    if (node is LeafNode) {
      buf.write(
          "LeafNode(tileId: GridIds.next(), tileType: '${node.tileType}')");
    } else if (node is SplitNode) {
      buf.writeln('SplitNode(');
      buf.writeln('$indent  vertical: ${node.vertical},');
      buf.writeln('$indent  ratio: ${node.ratio},');
      buf.write('$indent  a: ');
      _writeNode(buf, node.a, '$indent  ');
      buf.writeln(',');
      buf.write('$indent  b: ');
      _writeNode(buf, node.b, '$indent  ');
      buf.writeln(',');
      buf.write('$indent)');
    }
  }
}
