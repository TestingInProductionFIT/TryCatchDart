import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:serial/serial.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/prefs_keys.dart';

/// Stable id of the active telemetry connector (e.g. `'mock'`).
///
/// Persisted in [SharedPreferences]; unknown stored ids fall back to
/// [defaultConnectorId]. The settings toggle writes through [ConnectorIdStore.set];
/// replay playback overrides in memory ([persist] false) and restores on stop.
final activeConnectorIdProvider =
    AsyncNotifierProvider<ConnectorIdStore, String>(
  ConnectorIdStore.new,
);

/// The active [TelemetryConnector], resolved from [activeConnectorIdProvider].
///
/// Every connector-driven surface (FSM tile, control panel, command log,
/// flight events, capability gates) watches this: switching connectors
/// re-resolves states/commands/events/capabilities across the UI.
final activeConnectorProvider = Provider<TelemetryConnector>((ref) {
  final id = ref.watch(activeConnectorIdProvider).value ?? defaultConnectorId;
  return connectorById(id) ?? mockConnector;
});

class ConnectorIdStore extends AsyncNotifier<String> {
  static const String _prefsKey = PrefsKeys.connectorId;

  @override
  Future<String> build() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_prefsKey);
      if (raw != null && isKnownConnectorId(raw)) return raw;
    } catch (_) {
      // Corrupt settings must never take the app down.
    }
    return defaultConnectorId;
  }

  /// Selects the connector, persisting unless [persist] is false (replay's
  /// in-memory override). Unknown ids are ignored.
  Future<void> set(String id, {bool persist = true}) async {
    if (!isKnownConnectorId(id)) return;
    state = AsyncData(id);
    if (!persist) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_prefsKey, id);
    } catch (_) {
      // Persistence failure is non-fatal; state stays in memory.
    }
  }
}
