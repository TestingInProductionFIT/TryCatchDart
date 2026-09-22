import 'dart:convert';

import 'package:dead_reckoning/dead_reckoning.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/prefs_keys.dart';
import './telemetry_store.dart';

/// Active dead reckoning tune: persisted locally, applied live to the
/// telemetry store's estimator, edited from the tuning lab.
///
/// Starts at [DeadReckoningTune.defaults] (historical estimator behaviour)
/// and upgrades to the persisted tune once it loads — the estimator treats
/// a tune swap as forward-only (already-integrated offsets are kept).
final deadReckoningTuneProvider =
    NotifierProvider<DeadReckoningTuneController, DeadReckoningTune>(
        DeadReckoningTuneController.new);

class DeadReckoningTuneController extends Notifier<DeadReckoningTune> {
  @override
  DeadReckoningTune build() {
    _loadPersisted();
    return DeadReckoningTune.defaults;
  }

  /// Parses a persisted tune: compact string first, then raw JSON.
  /// Returns `null` when neither parses.
  static DeadReckoningTune? parsePersisted(String raw) {
    final compact = DeadReckoningTune.parseCompact(raw.trim());
    if (compact != null) return compact;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, Object?>) {
        return DeadReckoningTune.fromJson(decoded);
      }
    } catch (_) {
      // Malformed — caller keeps the current tune.
    }
    return null;
  }

  Future<void> _loadPersisted() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(PrefsKeys.deadReckoningTune);
      if (raw == null) return;
      final tune = parsePersisted(raw);
      if (tune == null) return;
      state = tune;
      _applyToStore();
    } catch (_) {
      // Storage unavailable — run on defaults.
    }
  }

  /// Activates [tune] live and persists it for the next session.
  Future<void> setTune(DeadReckoningTune tune) async {
    state = tune;
    _applyToStore();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
          PrefsKeys.deadReckoningTune, jsonEncode(tune.toJson()));
    } catch (_) {
      // Live tune still applies; persistence retries on the next change.
    }
  }

  /// Restores factory defaults (live + persisted).
  Future<void> resetToDefaults() => setTune(DeadReckoningTune.defaults);

  void _applyToStore() {
    ref.read(telemetryStoreProvider.notifier).setDeadReckoningTune(state);
  }
}
