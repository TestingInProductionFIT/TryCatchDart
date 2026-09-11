import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

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
    final flight = TileRegistry.defaultFlightLayout();
    final prep = TileRegistry.defaultPrepLayout();
    final recovery = TileRegistry.defaultRecoveryLayout();
    final replay = TileRegistry.defaultReplayLayout();
    return WorkspaceState(
        workspaces: [flight, prep, recovery, replay], activeId: flight.id);
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

  /// Persists the current in-memory state — called at the end of drags whose
  /// updates were applied without persistence.
  Future<void> persistActive() async {
    final current = state.value;
    if (current != null) await _persist(current);
  }

  /// Restores the factory layouts, discarding all custom workspaces.
  Future<void> resetToDefaults() async => _persist(_defaultState());
}
