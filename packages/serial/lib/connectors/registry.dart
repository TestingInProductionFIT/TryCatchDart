/// Registry of every available telemetry connector.
///
/// Adding a connector = one class + one entry here. The settings toggle,
/// the worker isolate and the recording readers all resolve through
/// [connectorById].
library;

import 'connector.dart';
import 'mock_connector.dart';

/// The MOCK connector instance (original TryCatch format).
const TelemetryConnector mockConnector = MockConnector();

/// Every available connector, in settings display order.
const List<TelemetryConnector> allConnectors = [mockConnector];

/// Default connector id (used before the persisted setting loads and as a
/// fallback for corrupt preferences).
const String defaultConnectorId = 'mock';

/// Resolves a connector by its stable [id], or `null` when unknown
/// (e.g. a recording from a connector this build doesn't ship).
TelemetryConnector? connectorById(String id) {
  for (final connector in allConnectors) {
    if (connector.id == id) return connector;
  }
  return null;
}

/// Whether [id] names a connector this build ships.
bool isKnownConnectorId(String id) => connectorById(id) != null;
