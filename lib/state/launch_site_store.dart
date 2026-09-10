import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/prefs_keys.dart';

/// A launch site: coordinates, MSL altitude and a display name.
class LaunchSite {
  final String name;
  final double latitude;
  final double longitude;

  /// Altitude above mean sea level in metres (used to convert barometric
  /// AGL readings to absolute position and to anchor the map).
  final double altitudeMsl;

  const LaunchSite({
    required this.name,
    required this.latitude,
    required this.longitude,
    required this.altitudeMsl,
  });

  LaunchSite copyWith({String? name, double? latitude, double? longitude, double? altitudeMsl}) =>
      LaunchSite(
        name: name ?? this.name,
        latitude: latitude ?? this.latitude,
        longitude: longitude ?? this.longitude,
        altitudeMsl: altitudeMsl ?? this.altitudeMsl,
      );

  Map<String, dynamic> toJson() => {
        'name': name,
        'latitude': latitude,
        'longitude': longitude,
        'altitudeMsl': altitudeMsl,
      };

  factory LaunchSite.fromJson(Map<String, dynamic> json) => LaunchSite(
        name: json['name'] as String? ?? '',
        latitude: (json['latitude'] as num?)?.toDouble() ?? 0,
        longitude: (json['longitude'] as num?)?.toDouble() ?? 0,
        altitudeMsl: (json['altitudeMsl'] as num?)?.toDouble() ?? 0,
      );
}

/// Selected launch site + saved presets.
class LaunchSiteState {
  final LaunchSite? selected;
  final List<LaunchSite> presets;

  const LaunchSiteState({this.selected, this.presets = const []});

  static const _absent = Object();

  /// `selected` uses a sentinel so callers can explicitly clear it with
  /// `copyWith(selected: null)`.
  LaunchSiteState copyWith({Object? selected = _absent, List<LaunchSite>? presets}) =>
      LaunchSiteState(
        selected: identical(selected, _absent)
            ? this.selected
            : selected as LaunchSite?,
        presets: presets ?? this.presets,
      );

  Map<String, dynamic> toJson() => {
        'selected': selected?.toJson(),
        'presets': presets.map((p) => p.toJson()).toList(),
      };

  factory LaunchSiteState.fromJson(Map<String, dynamic> json) =>
      LaunchSiteState(
        selected: json['selected'] == null
            ? null
            : LaunchSite.fromJson(json['selected'] as Map<String, dynamic>),
        presets: (json['presets'] as List<dynamic>? ?? [])
            .map((e) => LaunchSite.fromJson(e as Map<String, dynamic>))
            .toList(),
      );
}

/// Persisted launch-site settings ([shared_preferences], JSON-encoded).
final launchSiteProvider =
    AsyncNotifierProvider<LaunchSiteStore, LaunchSiteState>(
  LaunchSiteStore.new,
);

/// Synchronous convenience view of the currently selected site.
final currentLaunchSiteProvider = Provider<LaunchSite?>(
  (ref) => ref.watch(launchSiteProvider).value?.selected,
);

class LaunchSiteStore extends AsyncNotifier<LaunchSiteState> {
  static const String _prefsKey = PrefsKeys.launchSites;

  @override
  Future<LaunchSiteState> build() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_prefsKey);
      if (raw == null) return const LaunchSiteState();
      final loaded =
          LaunchSiteState.fromJson(jsonDecode(raw) as Map<String, dynamic>);
      final normalized = _normalize(loaded);
      if (!identical(normalized, loaded)) {
        // Best-effort: persist the repaired invariant (selection is always
        // one of the saved presets).
        try {
          await prefs.setString(_prefsKey, jsonEncode(normalized.toJson()));
        } catch (_) {}
      }
      return normalized;
    } catch (_) {
      // Corrupt settings must never take the app down.
      return const LaunchSiteState();
    }
  }

  /// Enforces the saved-only invariant: preset names are unique, the
  /// selection (when set) is one of the presets — a stray selection (e.g.
  /// from the old session-only flow) is adopted into the presets — and an
  /// empty selection with presets present falls through to the first.
  /// Returns the input when nothing needs repair.
  static LaunchSiteState _normalize(LaunchSiteState state) {
    final seen = <String>{};
    final presets = <LaunchSite>[];
    for (final p in state.presets) {
      if (seen.add(p.name)) presets.add(p);
    }
    var selected = state.selected;
    var changed = presets.length != state.presets.length;
    if (selected != null && !presets.any((p) => p.name == selected!.name)) {
      presets.add(selected);
      presets.sort((a, b) => a.name.compareTo(b.name));
      changed = true;
    } else if (selected == null && presets.isNotEmpty) {
      selected = presets.first;
      changed = true;
    }
    if (!changed) return state;
    return LaunchSiteState(selected: selected, presets: presets);
  }

  Future<void> _persist(LaunchSiteState next) async {
    state = AsyncData(next);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_prefsKey, jsonEncode(next.toJson()));
    } catch (_) {
      // Persistence failure is non-fatal; state stays in memory.
    }
  }

  /// Selects the active launch site (does not add a preset). A site is
  /// always selected — there is no "no site" state.
  Future<void> select(LaunchSite site) async =>
      _persist((state.value ?? const LaunchSiteState()).copyWith(selected: site));

  /// Adds or updates (by name) a preset and selects it.
  Future<void> savePreset(LaunchSite site) async {
    final current = state.value ?? const LaunchSiteState();
    final presets = [...current.presets]
      ..removeWhere((p) => p.name == site.name)
      ..add(site)
      ..sort((a, b) => a.name.compareTo(b.name));
    await _persist(current.copyWith(presets: presets, selected: site));
  }

  /// Deletes a preset by name. When the deleted preset was the selected
  /// site, selection falls through to the first remaining preset — or to
  /// nothing when none remain (the empty state that prompts adding a site).
  Future<void> deletePreset(String name) async {
    final current = state.value ?? const LaunchSiteState();
    final remaining =
        current.presets.where((p) => p.name != name).toList();
    final wasSelected = current.selected?.name == name;
    await _persist(current.copyWith(
      presets: remaining,
      selected: wasSelected
          ? (remaining.isNotEmpty ? remaining.first : null)
          : current.selected,
    ));
  }
}
