# TryCatch — Dart Ground Station App: Architecture & Design

> **Purpose**: Comprehensive reference for agents (or humans) building the TryCatch Flutter desktop app. Read this first, then `packet_and_storage_spec.md` for wire formats, and `ui_spec.md` for UI details.

---

## 0. Context & Background

TryCatch is a ground station app for a Czech model rocket (team "Testing in Production", Czech Rocket Challenge). The rocket transmits binary telemetry via LoRa radio to an **ESP32 TTGO LoRa32** ground receiver. The receiver forwards raw packets over USB serial at **115200 baud**. This app replaces a previous Node.js + PostgreSQL + React stack.

**Key sources studied:**
- `ErrorHandler/` — ESP32 PlatformIO firmware (LoRa receiver, sends raw binary to serial)
- `TryCatch/` — Previous TS/React implementation (Node.js + Socket.IO + PostgreSQL)
- `CRCVisualization/` — Previous browser-based flight replay tool (vanilla JS, Three.js, Chart.js)

The rocket's avionics and sensor suite **will change between flights and firmware versions**. The app must accommodate packet format evolution gracefully.

---

## 1. Goals & Non-Goals

### Goals
- Single self-contained executable — no server, no database server, no internet required
- Runs on: **Windows x64, Windows ARM64, Linux x64/ARM64, macOS x64/ARM64**
- **Daylight-Optimized Light Theme**: Designed specifically for high visibility on laptop screens outdoors under bright sunlight
- Real-time telemetry display from serial port (ESP32 LoRa receiver)
- Record flights to crash-safe, portable single files (one file per flight)
- Replay recorded flights with scrubber and variable speed
- Export flight subsets to CSV / JSONL / RKTF
- Send uplink commands to the rocket via serial
- Settings profiles (launch site, codec version, preferences) that persist across launches
- Modular packet system: adding/changing packet fields requires minimal changes (codec + field descriptors only, UI adapts automatically)

### Non-Goals (v1)
- No web or mobile support
- No cloud sync
- No real-time collaboration
- No live map tile downloads required (tiles are cached; app works offline after first load)
- No user-configurable tile drag-and-drop layout (layout is fixed but code is modular)

---

## 2. Technology Stack

| Concern | Package | Notes |
|---|---|---|
| Framework | `flutter` 3.x stable | Desktop target |
| State management | `flutter_riverpod` + `riverpod_annotation` | Code-gen providers |
| Navigation | `go_router` | Shell routes, nested navigation |
| Serial port | `flutter_libserialport` | Wraps `libserialport` C lib; cross-platform |
| Database (index) | `drift` | SQLite ORM with migrations |
| File I/O | `dart:io` | Direct file access for `.rktf` flight files |
| Charts | `fl_chart` | Canvas-based, performant for real-time updates in light mode |
| Map | `flutter_map` + `latlong2` | OSM tiles, tile caching, no API key |
| Settings persistence | `shared_preferences` | Simple KV; profiles stored as JSON |
| File picker | `file_picker` | Export destination picker |
| Immutable models | `freezed` + `json_serializable` | Code-gen data classes |
| Math | `vector_math` | Quaternions/matrices for 3D orientation widget |
| Path utils | `path_provider` | App documents directory |
| Build | `riverpod_generator`, `build_runner` | Code generation |

---

## 3. Project Structure

```
TryCatchDart/
├── ai/                              ← AI/design docs & Knowledge Base
│   ├── README.md                    ← Knowledge base index
│   ├── design.md                    ← this file
│   ├── packet_and_storage_spec.md   ← wire formats, .rktf file format
│   └── ui_spec.md                   ← UI layout, light theme, tiles, commands
│
├── lib/
│   ├── main.dart                    ← entry point, ProviderScope, codec registration
│   │
│   ├── core/                        ← shared primitives, no deps on other layers
│   │   ├── constants.dart           ← AppConstants class (all magic numbers)
│   │   ├── result.dart              ← Result<T,E> sealed class
│   │   ├── circular_buffer.dart     ← fixed-size FIFO ring buffer
│   │   └── extensions/
│   │       ├── datetime_ext.dart    ← formatting helpers
│   │       ├── double_ext.dart      ← toFixed(), toSignedString()
│   │       └── bytes_ext.dart       ← Uint8List helpers (toHex, etc.)
│   │
│   ├── packet/                      ← PACKET SYSTEM — most critical for modularity
│   │   ├── packet_codec.dart        ← abstract PacketCodec<T extends TelemetryPacket>
│   │   ├── telemetry_packet.dart    ← abstract TelemetryPacket interface
│   │   ├── field_descriptor.dart    ← FieldDescriptor class, FieldCategory enum
│   │   ├── codec_registry.dart      ← CodecRegistry singleton
│   │   └── codecs/
│   │       └── v1/
│   │           ├── v1_codec.dart    ← V1PacketCodec (33-byte current format)
│   │           └── v1_packet.dart   ← V1Packet (freezed)
│   │
│   ├── serial/
│   │   ├── serial_service.dart      ← open/close port, raw byte stream, write()
│   │   ├── port_scanner.dart        ← auto-detect ESP32 by VID/PID
│   │   └── frame_synchronizer.dart  ← sync word scanner, emits aligned frames
│   │
│   ├── flight/
│   │   ├── flight_model.dart        ← Flight, FlightSummary (freezed)
│   │   ├── flight_recorder.dart     ← writes .rktf + DB index per packet
│   │   └── flight_repository.dart   ← list, load, delete, crash-recovery scan
│   │
│   ├── storage/
│   │   ├── database/
│   │   │   ├── app_database.dart    ← Drift DB + migration setup
│   │   │   ├── tables/
│   │   │   │   ├── flights_table.dart
│   │   │   │   └── packet_index_table.dart
│   │   │   └── daos/
│   │   │       ├── flights_dao.dart
│   │   │       └── packet_index_dao.dart
│   │   └── file/
│   │       ├── rktf_format.dart     ← magic bytes, version constants, offsets
│   │       ├── rktf_writer.dart     ← append-only crash-safe binary writer
│   │       └── rktf_reader.dart     ← header parse + streaming/seek read
│   │
│   ├── replay/
│   │   ├── replay_controller.dart   ← StateNotifier: play/pause/seek/speed/selection
│   │   └── replay_service.dart      ← loads .rktf, emits packets at correct rate
│   │
│   ├── export/
│   │   ├── export_service.dart      ← orchestrates range + format selection
│   │   ├── csv_exporter.dart        ← RFC 4180 CSV from packet list
│   │   └── jsonl_exporter.dart      ← newline-delimited JSON
│   │
│   ├── commands/
│   │   ├── rocket_command.dart      ← RocketCommand enum + byte arrays
│   │   └── command_service.dart     ← sends command 3x via serial for redundancy
│   │
│   ├── settings/
│   │   ├── app_settings.dart        ← AppSettings (freezed)
│   │   ├── launch_profile.dart      ← LaunchProfile (freezed)
│   │   └── settings_repository.dart ← persist via shared_preferences
│   │
│   ├── providers/                   ← Riverpod providers (thin wiring layer only)
│   │   ├── serial_providers.dart
│   │   ├── flight_providers.dart
│   │   ├── telemetry_providers.dart
│   │   ├── replay_providers.dart
│   │   └── settings_providers.dart
│   │
│   └── ui/
│       ├── app.dart                 ← MaterialApp.router + GoRouter config
│       ├── theme/
│       │   ├── app_theme.dart       ← ThemeData (Light outdoor high-contrast)
│       │   └── app_colors.dart      ← color palette constants
│       ├── shell/
│       │   ├── app_shell.dart       ← ShellRoute scaffold: top bar + nav tabs
│       │   ├── port_selector.dart   ← always-visible port dropdown + connect btn
│       │   └── connection_status.dart ← animated indicator dot
│       ├── screens/
│       │   ├── live/
│       │   │   └── live_screen.dart
│       │   ├── replay/
│       │   │   ├── replay_screen.dart
│       │   │   └── flight_list_panel.dart
│       │   └── settings/
│       │       └── settings_screen.dart
│       ├── tiles/                   ← MODULAR TILE WIDGETS
│       │   ├── tile_base.dart       ← abstract TelemetryTile
│       │   ├── altitude_graph_tile.dart
│       │   ├── velocity_graph_tile.dart
│       │   ├── acceleration_graph_tile.dart
│       │   ├── tribo_graph_tile.dart
│       │   ├── packet_stats_tile.dart
│       │   ├── gps_map_tile.dart
│       │   ├── orientation_3d_tile.dart
│       │   ├── battery_status_tile.dart
│       │   ├── fsm_state_tile.dart
│       │   ├── pressure_tile.dart
│       │   ├── hall_sensor_tile.dart
│       │   └── command_panel_tile.dart
│       ├── replay_controls/
│       │   ├── replay_transport.dart   ← play/pause/seek/speed bar
│       │   └── range_selector.dart     ← drag handles for export range
│       └── widgets/                 ← small shared widgets
│           ├── rolling_chart.dart   ← reusable real-time line chart (fl_chart)
│           ├── confirm_button.dart  ← 2-click safety button
│           ├── value_display.dart   ← label + value + unit, monospace numbers
│           └── section_header.dart
│
├── test/
│   ├── packet/
│   │   └── v1_codec_test.dart
│   ├── serial/
│   │   └── frame_synchronizer_test.dart
│   └── storage/
│       └── rktf_roundtrip_test.dart
│
├── pubspec.yaml
├── analysis_options.yaml
└── README.md
```

---

## 4. Core Abstractions

### 4.1 TelemetryPacket
```dart
abstract class TelemetryPacket {
  int get codecVersion;
  DateTime get receivedAt;
  double? get rssi;
  Uint8List get rawBytes;
  Map<String, dynamic> toFieldMap();
}
```

### 4.2 PacketCodec
```dart
abstract class PacketCodec<T extends TelemetryPacket> {
  int get version;
  int get packetLength;
  List<int>? get syncPattern;
  T? decode(Uint8List bytes, {required DateTime receivedAt, double? rssi});
  List<FieldDescriptor> get fields;
  String get versionLabel;
}
```

### 4.3 FieldDescriptor
```dart
class FieldDescriptor {
  final String key;
  final String label;
  final String unit;
  final FieldCategory category;
  final double? minValue;
  final double? maxValue;
  final double? warningMin;
  final double? warningMax;
  final Color? defaultColor;
  final String? description;
}

enum FieldCategory {
  navigation,
  imu,
  power,
  sensor,
  system,
  raw,
}
```

### 4.4 CodecRegistry
```dart
class CodecRegistry {
  static final CodecRegistry instance = CodecRegistry._();
  CodecRegistry._();

  final Map<int, PacketCodec> _codecs = {};

  void register(PacketCodec codec) => _codecs[codec.version] = codec;
  PacketCodec? byVersion(int version) => _codecs[version];
  PacketCodec get latest => _codecs.values.reduce((a, b) => a.version > b.version ? a : b);
  List<PacketCodec> get all => _codecs.values.toList()..sort((a, b) => a.version.compareTo(b.version));
}
```

---

## 5. Serial & Command Communication

- **Framing**: Raw bytes streamed from `flutter_libserialport` @ 115200 baud. `FrameSynchronizer` scans for sync word `[0xA5, 0x5A]` and slices fixed `packetLength` (33 bytes for V1).
- **Auto-Detection**: Scans USB devices for CP210x (`0x10C4:0xEA60`), CH340 (`0x1A86:0x7523`), FT232 (`0x0403:0x6001`).
- **Commands**: Uplink commands are 4 bytes written to serial port 3 times (0ms, 100ms, 200ms) for RF reliability.

---

## 6. Flight Recording & Storage (.rktf)

- **Primary Store**: One `.rktf` binary file per flight in `{UserDocuments}/TryCatch/flights/`.
- **Index**: SQLite `flights.db` for fast flight listing, packet indexing, and seek offset lookup.
- **Crash Recovery**: On startup, files in `flights/` are scanned and re-indexed into SQLite if DB is missing or corrupted.

---

## 7. Replay & Export

- **Replay**: `ReplayController` reads packet stream from `.rktf` and emits packets respecting real timestamps / user speed multiplier (0.25x - 10x). O(1) seek via byte offset table.
- **Export**: Full flight or user-selected range can be exported to `.csv`, `.jsonl`, or a trimmed `.rktf`.
