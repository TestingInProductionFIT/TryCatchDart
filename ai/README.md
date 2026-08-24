# TryCatch Ground Station — AI Knowledge Base & Specs

Welcome to the AI knowledge base and engineering specifications for **TryCatch Ground Station**, a single, self-contained multiplatform Dart/Flutter desktop application (Windows x64/ARM64, Linux x64/ARM64, macOS x64/ARM64).

## Knowledge Base Contents

1. **[`design.md`](./design.md)**:
   - Architectural principles, goals & non-goals.
   - Technology stack rationale (Flutter, Riverpod, Drift SQLite, flutter_libserialport, fl_chart, flutter_map).
   - Core abstractions (`TelemetryPacket`, `PacketCodec`, `FieldDescriptor`, `CodecRegistry`).
   - Project directory layout and implementation order.
   - Riverpod provider dependency graph.
   - Performance budgets, debouncing, and error handling.

2. **[`packet_and_storage_spec.md`](./packet_and_storage_spec.md)**:
   - Complete byte layout for V1 telemetry packets (33-byte packed struct) and physical unit conversions.
   - Evolution strategy: how to add V2, V3+ packets without breaking older flights.
   - `.rktf` (Rocket Telemetry Format) custom binary container specification (file header, packet records, metadata chunk, CRC16 checksums).
   - SQLite index schema and crash-recovery procedures.
   - CSV and JSONL export formats.

3. **[`ui_spec.md`](./ui_spec.md)**:
   - High-contrast telemetry UI layout (dark theme, color tokens, typography).
   - Top status bar: always-visible serial port selector, baud rate, link stats, 2-click recording controller.
   - Live Dashboard layout: primary flight instruments, rolling charts, 3D rocket orientation preview, OpenStreetMap GPS track.
   - Replay Dashboard: timeline scrubber, dual-handle range selection for export, variable speed playback (0.25x to 10x).
   - Rocket Command Console: safety armed/confirm mechanism, 4-byte command set.
   - Settings & Launch Profiles: GPS launch site management, profile persistence.

---

## Key Design Principles Summary

1. **Modular Packet Evolution**: Packet decoding logic is completely decoupled from UI rendering via `PacketCodec` and `FieldDescriptor`. Any new sensor struct version can be added by implementing a new codec without touching UI widgets.
2. **Crash-Safe Single-File Storage**: Flights are recorded to `.rktf` binary files with periodic byte flushes. Even if the laptop battery dies mid-flight, all captured packets up to the crash are fully recoverable and portable.
3. **High Performance**: UI charts and maps are debounced (30 fps for charts, 2 fps for GPS map), and replay random access is $O(1)$ via precomputed record offset seek tables.
