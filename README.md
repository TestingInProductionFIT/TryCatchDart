# {TryCatch}

Ground station for model rockets — _Testing in Production_.

A Flutter Windows desktop app that receives telemetry from a rocket over a
serial link, displays it live on a fully tileable dashboard, records flights
to disk and replays them, and (eventually) sends commands back to the rocket.

## Features

- **Live telemetry** — 10 Hz frames over a serial port, parsed and CRC-checked
  in a background isolate. No hardware? The built-in **MOCK** port runs a
  deterministic full-flight simulator (pad → ascent → apogee → parachute →
  landed), so the whole app is demoable without a rocket.
- **Tiling dashboard** — hyprland-style workspaces backed by a KD-tree layout
  tree. Every split keeps its widgets' minimum sizes; drag dividers to resize,
  double-click a divider (in edit mode) to flip a split between horizontal and
  vertical, drag tiles onto each other to swap them. Workspaces are persisted.
- **12 widget types** — time-series charts (altitude, pressure, velocity,
  acceleration, battery, hall sensor), map with GPS + dead-reckoning tracks, 3D rocket
  attitude view, 3D flight path, flight-state machine, stats, and a two-click
  command panel. Adding a widget = one class + one registry entry.
- **Raw data, no smoothing** — every chart shares one code path and plots the
  raw telemetry.
- **Recording & replay** — raw serial chunks are dumped to
  `Documents/TryCatch/recordings/*.bin` (v1 files open with a 112-byte
  header: launch site, time span, packet count and peaks, so the grid lists
  stats without decoding; headerless files are rejected) and can be replayed
  with seek and speed control.
- **Ground-side dead reckoning** — a decoupled estimation module fills GPS
  gaps (≥1 s of silence) so tracks and the 3D flight view stay connected.
- **Raw monitor** — a full-screen monospace hex dump of the packet stream for
  debugging the link.

## Getting started

Prerequisites: [Flutter](https://docs.flutter.dev/get-started/install/windows)
(SDK ^3.13) with Windows desktop support.

```powershell
flutter pub get
flutter run -d windows
```

Then pick the `MOCK` port in the top bar and hit **Connect** — no radio
hardware required. To use real hardware, select the rocket's COM port instead
(baud rate and framing live in `packages/serial`).

Debug builds are janky; use `flutter run -d windows --release` when evaluating
feel and performance.

## The wire format is a placeholder

The serial frame format (53-byte payload: GPS, barometer, IMU, attitude,
battery, hall sensor, FSM state + CRC16-CCITT) is **made up** until the real
flight software exists. It is versioned and CRC-checked so it can evolve;
legacy 52-byte recordings still replay. The command panel's byte catalog is
likewise a placeholder and **must be aligned with the real firmware before
flight** — arming and pyro commands require a two-click confirmation.

See `packages/serial/lib/telemetry/frame_codec.dart` for the layout.

## Project layout

```
lib/
  app/            chrome: top bar, playback, router, raw-monitor screen
  theme/          "Precision Light" design system (colors, text, cards, pills)
  workspaces/     KD-tree layout, workspace controller, dashboard + widgets
  flights/        recording list + replay controller
  settings/       launch-site presets
  components/     raw byte monitor
  src/
    telemetry/    ingestion store (ring buffers, packet rate, DR pump)
    estimation/   ground-side dead reckoning
    geo/          haversine & offset helpers
    collections/  ring buffer (zero-copy views)
packages/serial/  framing, codec, worker isolate, mock simulator
test/             unit + widget tests (62)
design_mockups/   HTML mockups from the design exploration (reference only)
```

## Design

Light-mode **"Precision Light"**: white cards on a cool grey desk, hairline
borders, monospace micro-labels for anything technical, and the team pink
`#FF00A1` as the single accent (status colors stay green/amber/red). Layout
and platform notes — including why card shadows/anti-aliased clips are
avoided on Windows ARM64 (Impeller/OpenGLES blank-paint bug) — are documented
in [HANDOFF.md](HANDOFF.md), which doubles as the deep-dive: architecture
decisions, widget registry, replay pipeline, and current state.

## Development

```powershell
flutter analyze   # keep it clean
flutter test      # 62 tests, keep them green
```

Riverpod 3 (no codegen), no router package, no build_runner. Adding a
dashboard widget is one class plus one `WidgetRegistry` entry — min size,
title and builder included.
