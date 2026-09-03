import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

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
  static const String _prefsKey = 'trycatch.launch_sites.v1';

  @override
  Future<LaunchSiteState> build() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_prefsKey);
      if (raw == null) return const LaunchSiteState();
      return LaunchSiteState.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      // Corrupt settings must never take the app down.
      return const LaunchSiteState();
    }
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

  /// Selects the active launch site (does not add a preset).
  Future<void> select(LaunchSite? site) async =>
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

  /// Deletes a preset by name; deselects it if it was active.
  Future<void> deletePreset(String name) async {
    final current = state.value ?? const LaunchSiteState();
    final wasSelected = current.selected?.name == name;
    await _persist(current.copyWith(
      presets: current.presets.where((p) => p.name != name).toList(),
      selected: wasSelected ? null : current.selected,
    ));
  }
}
