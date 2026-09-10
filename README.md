# {TryCatch}

Ground station for model rockets — _Testing in Production_.

A Flutter desktop app that receives telemetry from a rocket over a
serial link, displays it live on a fully tileable dashboard, records flights
to disk and replays them, and sends commands back to the rocket.

## Platforms

Windows (x86_64 + ARM64), Linux and macOS — all three desktop shells are
scaffolded (`windows/`, `linux/`, `macos/`). Primary dev target is Windows.

## Features

- **Live telemetry** — 10 Hz frames over a serial port, parsed and CRC-checked
  in a background isolate. No hardware? The built-in **MOCK** port runs a
  deterministic full-flight simulator (pad → ascent → apogee → parachute →
  landed), so the whole app is demoable without a rocket.
- **Tiling dashboard** — hyprland-style workspaces backed by a KD-tree layout
  tree. Every split keeps its tiles' minimum sizes; drag dividers to resize,
  double-click a divider (in edit mode) to flip a split between horizontal and
  vertical, drag tiles onto each other to swap them. Workspaces are persisted.
- **14 tile types** — time-series charts (altitude, velocity,
  acceleration, battery, hall sensor), map with GPS + dead-reckoning tracks, 3D rocket
  attitude view, 3D flight path (plain + satellite), flight-state machine, position, and a two-click
  command panel. Adding a tile = one class + one `TileRegistry` entry.
- **Raw data, no smoothing** — every chart shares one code path and plots the
  raw telemetry.
- **Recording & replay** — raw serial chunks are dumped to
  `Documents/TryCatch/recordings/*.bin` (files open with a 108-byte
  header: launch site, time span, packet count and peaks, so the grid lists
  stats without decoding; files without a header are rejected) and can be replayed
  with seek and speed control.
- **Ground-side dead reckoning** — a decoupled estimation module fills GPS
  gaps (≥1 s of silence) so tracks and the 3D flight view stay connected.
- **Channel health** — a live monitor of bytes/s on the
  frequency that are not our packets, with an all-clear/activity/
  interference verdict, for checking the frequency is free before launch.
  A pill in the top bar mirrors the verdict live.

## Getting started

Prerequisites: [Flutter](https://docs.flutter.dev/get-started/install) (SDK ^3.13)
with desktop support for your OS.

```powershell
flutter pub get
flutter run -d windows   # or -d linux / -d macos
```

Then pick the `MOCK` port in the top bar and hit **Connect** — no radio
hardware required. To use real hardware, select the rocket's serial port instead
(baud rate and framing live in `packages/serial`).

Debug builds are janky; use `flutter run -d windows --release` when evaluating
feel and performance.

## The wire format is a placeholder

The serial frame format (52-byte payload: GPS, barometer, IMU, attitude,
battery, hall sensor, FSM state + CRC16-CCITT) is **made up** until the real
flight software exists. It is CRC-checked so corruption is caught; there is
a single format with no versioning. The command panel's byte catalog is
likewise a placeholder and **must be aligned with the real firmware before
flight** — arming and pyro commands require a two-click confirmation.

See `packages/serial/lib/telemetry/frame_codec.dart` for the layout.

## Project layout

```
lib/
  ui/screens/     app chrome + screens (shell, dashboard, recordings, settings, monitor)
  ui/components/  shared chrome (top bar, cards, pills, buttons, placeholders)
  ui/tiles/       telemetry tiles + shared/ (charts, 3D scene, tile I/O)
  state/          Riverpod stores (telemetry, replay, workspaces, launch sites, router)
  services/       app services (recording trim, prefs keys)
  core/           pure logic (geo, dead reckoning, ring buffer, formats)
  theme/          "Precision Light" design system (colors, text, theme)
packages/serial/  framing, codec, worker isolate, mock simulator
test/             unit + widget tests (144)
design_mockups/   HTML mockups from the design exploration (reference only)
```

## Design

**"Precision Light"** (plus a dark companion): cards on a cool grey desk, hairline
borders, monospace micro-labels for anything technical, and the team pink
`#FF00A1` as the single accent (status colors stay green/amber/red). Platform
notes — including why card shadows/anti-aliased clips are
avoided on Windows ARM64 (Impeller/OpenGLES blank-paint bug) — are documented
in [HANDOFF.md](HANDOFF.md), which doubles as the deep-dive: architecture
decisions, tile registry, replay pipeline, and current state.

## Development

```powershell
flutter analyze   # keep it clean
flutter test      # 144 tests, keep them green
```

Riverpod 3 (no codegen), no router package, no build_runner. Adding a
dashboard tile is one class plus one `TileRegistry` entry — min size,
title and builder included.
