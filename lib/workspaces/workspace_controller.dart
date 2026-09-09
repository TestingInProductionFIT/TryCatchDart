import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'layout_tree.dart';
import 'widget_registry.dart';
import 'workspace_models.dart';

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
    final activeId = json['activeId'] as String?;
    return WorkspaceState(
      workspaces: workspaces,
      activeId: workspaces.any((w) => w.id == activeId)
          ? activeId!
          : (workspaces.isEmpty ? '' : workspaces.first.id),
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
  static const String _prefsKey = 'trycatch.workspaces.v1';

  MinSizeLookup get _minOf => (typeId) => WidgetRegistry.minSizeOf(typeId);

  @override
  Future<WorkspaceState> build() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_prefsKey);
      if (raw != null) {
        final loaded =
            WorkspaceState.fromJson(jsonDecode(raw) as Map<String, dynamic>);
        if (loaded.workspaces.isNotEmpty) {
          return _migrate(loaded);
        }
      }
    } catch (_) {
      // Corrupt persistence falls through to defaults.
    }
    return _defaultState();
  }

  WorkspaceState _defaultState() {
    final flight = WidgetRegistry.defaultFlightLayout();
    final prep = WidgetRegistry.defaultPrepLayout();
    final replay = WidgetRegistry.defaultReplayLayout();
    return WorkspaceState(
        workspaces: [flight, prep, replay], activeId: flight.id);
  }

  /// Ensures factory workspaces added after first launch (e.g. Replay) exist
  /// in persisted states without discarding the user's custom arrangements.
  WorkspaceState _migrate(WorkspaceState loaded) {
    if (loaded.workspaces.any((w) => w.name == 'Replay')) return loaded;
    return loaded.copyWith(
      workspaces: [...loaded.workspaces, WidgetRegistry.defaultReplayLayout()],
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

  String _uniqueName(List<Workspace> existing, String base) {
    var name = base;
    var i = 2;
    while (existing.any((w) => w.name == name)) {
      name = '$base ${i++}';
    }
    return name;
  }

  // ── Layout tree mutations ───────────────────────────────────────────────────

  /// Adds a widget by splitting the largest leaf of the active workspace —
  /// or, with [splitWidgetId], by splitting that specific tile instead.
  Future<void> addWidget(String typeId, {String? splitWidgetId}) async {
    await _updateActive((ws) {
      final result = splitWidgetId == null
          ? insertLeaf(ws.root, typeId, GridIds.next(), _minOf)
          : splitLeaf(ws.root, splitWidgetId, typeId, GridIds.next(), _minOf);
      return result == null ? ws : ws.copyWith(root: result.root);
    });
  }

  Future<void> removeWidget(String widgetId) async {
    await _updateActive(
      (ws) => ws.copyWith(root: removeLeaf(ws.root, widgetId)),
    );
  }

  /// Swaps the content of two leaves (drag a widget onto another in edit mode).
  Future<void> swapWidgets({
    required String widgetId,
    required String ontoWidgetId,
    bool persist = true,
  }) async {
    await _updateActive(
      (ws) => ws.copyWith(
          root: swapLeaves(ws.root, widgetId, ontoWidgetId)),
      persist: persist,
    );
  }

  /// Updates a split ratio (divider drag), located by stable node id.
  Future<void> setRatio({
    required String nodeId,
    required double ratio,
    bool persist = true,
  }) async {
    await _updateActive(
      (ws) => ws.copyWith(root: _setRatio(ws.root, nodeId, ratio)),
      persist: persist,
    );
  }

  /// Flips a split between horizontal and vertical (double-click on a
  /// divider in edit mode), located by stable node id.
  Future<void> toggleSplitOrientation({required String nodeId}) async {
    await _updateActive(
      (ws) => ws.copyWith(root: _flipOrientation(ws.root, nodeId)),
    );
  }

  LayoutNode? _flipOrientation(LayoutNode? node, String nodeId) {
    if (node == null) return null;
    if (node is SplitNode) {
      if (node.id == nodeId) return node.flipOrientation();
      final newA = _flipOrientation(node.a, nodeId);
      final newB = _flipOrientation(node.b, nodeId);
      if (!identical(newA, node.a) || !identical(newB, node.b)) {
        return node.withChildren(a: newA, b: newB);
      }
      return node;
    }
    return node;
  }

  LayoutNode? _setRatio(LayoutNode? node, String nodeId, double ratio) {
    if (node == null) return null;
    if (node is SplitNode) {
      if (node.id == nodeId) return node.withRatio(ratio);
      final newA = _setRatio(node.a, nodeId, ratio);
      final newB = _setRatio(node.b, nodeId, ratio);
      if (!identical(newA, node.a) || !identical(newB, node.b)) {
        return node.withChildren(a: newA, b: newB);
      }
      return node;
    }
    return node;
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
