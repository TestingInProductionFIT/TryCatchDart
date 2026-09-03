# TryCatchDart — Project Context & Handoff

> Ground station for model rockets ("Testing in Production"). Flutter Windows
> desktop app, light-mode shadcn-inspired UI. This file compacts all relevant
> knowledge, decisions and current state. Update it when things change.

## 1. Stack & conventions

- Flutter (SDK ^3.13), Windows desktop target, run from `C:\Users\wwwho\flutter`.
- **Riverpod 3** (no codegen): `Notifier` / `AsyncNotifier`, `AsyncValue.value`
  (NOT `valueOrNull`), `ProviderScope.overrides` injects the worker in main.
- `fl_chart` 1.2 (notes: `SideTitleWidget(meta: meta, child:)`,
  `LineChart(duration: Duration.zero)`, `StrokePattern.dashed`, `BarAreaData`,
  old API `BorderSide.strokeAlignInside` is a double, not an enum).
- `flutter_map` 8.3 + `latlong2`, `vector_math` 2.4.2
  (`transformed(Vector4)`, `transformed3(Vector3)`, `scaleByDouble(x,y,z,w)`),
  `shared_preferences`, `path_provider`, `window_manager`, `tray_manager`,
  `flutter_libserialport`, local package `packages/serial`.
- No router package (4 flat screens via enum provider). No build_runner/freezed.
- Theme: `lib/theme/` — **"Precision Light"** design language (2026-09 redesign,
  chosen from HTML mockups in `design_mockups/`, then **softened after user
  feedback — "not brutalist, more modern"**): light engineering aesthetic,
  white cards (radius 12/8) on cool grey `#F5F4F6`, soft hairline borders,
  faint shadows, monospace micro-labels (Consolas via `AppText`) for anything
  technical, and the team pink `#FF00A1` as the single accent (neon pink for
  graphics/live indicators, `pinkDeep #D6008A` for text-safe accents; status
  stays green/amber/red so pink stays special). `AppColors`, `AppDimens`,
  `AppText`, `AppCard` (header = pink dot + mono uppercase label + hairline
  divider — **no tinted band**), `StatusPill` (mono uppercase stadium, soft
  wash + faint border), `WaitingForData`. Top bar: **no vertical rules** —
  spacing only, micro-labels (LINK / PACKETS / REC). Workspace tabs: text tabs
  with a 2.5px pink underline flush on the strip hairline (full-height tab
  containers, so all tabs align). Series colors: baro alt = pink,
  GPS/horiz = blue, DR/battery = violet, vert = green, accel = amber,
  total/ink = foreground. Default font (user declined bundling Inter).
- **Outside edit mode**: no visible dividers between tiles, and "Add widget"/"Reset"
  strip buttons are hidden (only "Edit layout" shows). Edit mode reveals
  dividers, drag-to-swap, per-tile split/remove, Add widget and Reset.
- **2026-09 "blank tiles in live mode" root cause**: Impeller's OpenGLES
  backend on Windows ARM64 silently stopped painting the workspace grid
  (layout verified correct via `[grid]` debug print; no exceptions). Trigger
  was paint introduced by the redesign — per-card `BoxShadow` +
  `Clip.antiAlias` on every grid tile. Fix (Impeller stays ON for perf):
  `AppCard` has **no boxShadow** and uses `Clip.hardEdge` — do not reintroduce
  card shadows or anti-aliased clips on grid tiles without testing on
  Windows ARM64. The workspace grid also keeps dividers as (invisible)
  `Positioned` children in live mode so the Stack's child shape is identical
  in both modes. Fallback if it ever regresses: `project_.set_impeller_switch(
  flutter::ImpellerSwitch::Disabled)` in `windows/runner/flutter_window.cpp`
  switches to Skia.
- Analyzer must stay clean; `flutter test` green (58 tests).

## 2. Serial package (`packages/serial`) — wire format is a MADE-UP placeholder

Framing: sync `0xAA55` + payload 53 bytes (includes trailing CRC16). Payload map
(`telemetry/frame_codec.dart` `TelemetryLayout`, big-endian):

```
0  version u8 (=1)      1  flags u8 (bit0 gpsFix, bit1 gpsFix3d)
2  seq u16              4  gpsLat i32 1e-7deg     8  gpsLon i32 1e-7deg
12 gpsAlt i32 cm        16 baroAlt i32 cm       20 velN i16 cm/s   22 velE   24 velD
26 accelX/Y/Z i16 mg    32 gyroX/Y/Z i16 centidps (±327 dps)
38 heading u16 centideg 40 roll i16 centideg 42 pitch 44 yaw
46 battery u16 mV       48 hall u16 raw (~2500 intact / ~2950 broken)
50 fsmState u8          51 crc16-ccitt(u16, init 0xFFFF, poly 0x1021)
```

- Units: WGS84 deg, metres, NED velocity (Down positive), body-frame specific
  force (+9.81 at rest), gyro deg/s, **rocket-oriented attitude**:
  pitch = tilt from vertical, yaw = compass heading, roll = spin about axis.
- `FsmState` ids: idle 0, armed 1, boost 2, coast 3, apogee 4, drogue 5,
  main 6, landed 7, fault 8, unknown 255.
- `FrameCodec.decode` auto-detects generation by length: 53 = current,
  **52 = legacy** (hall was u8 0/1@48, fsm@49, crc@50; mapped to 2500/2950).
  The ancient **31-byte format is random bytes, unsupported** (no CRC).
- CRC16-CCITT check vector: `"123456789"` → 0x29B1.
- `PacketParser(payloadLength: …)` — parametrizable for legacy replay.
- **FlightSimulator** (`telemetry/flight_simulator.dart`, seeded/deterministic):
  coldStart 2 s (no fix) → pad 6 s (armed after 2 s) → boost 2.8 s @ 55 m/s² →
  coast (drag 4e-4) → apogee ~1058 m + hall break → drogue (~40 m/s) →
  main @150 m (~6 m/s, chute accel clamped 40 m/s²) → landed (pitch 85°).
  GPS random-walk error, eastward wind drift under canopy, battery 8.4 V →
  −2.5 mV/s. Launch site Prague (50.0755, 14.4378). `MockSerialPort` runs it
  at 10 Hz through `FrameCodec.encodePacket`.
- Worker isolate (`worker/`): typed commands/events over SendPort.
  Commands: Connect/Disconnect/ListPorts/StartRecording/StopRecording/
  **SendBytesCommand(bytes)** (control panel). Events: PacketReceived/
  PortList/StatusChanged/Error. Recorder dumps raw chunks with 12-byte header
  (i64 µs big-endian + u32 len); FileParser streams them back with original
  timestamps.

## 3. App architecture

```
lib/
  main.dart                 worker spawn → ProviderScope override → AppShell (fullscreen, tray, preventClose)
  app/                      AppShell, router (enum), TopBar (replay-aware), BrandMark,
                            SerialControls, PacketRateIndicator, RecordingControls, PlaybackBar, MonitorScreen
  theme/                    app_colors, app_theme (buildAppTheme), widgets/{app_card,status_pill,waiting_for_data}
  src/telemetry/            telemetry_provider (worker providers + SerialConfigNotifier incl. sendBytes)
                            telemetry_store (THE ingestion point), packet_rate_tracker
  src/estimation/           dead_reckoning (ground-side DR; only extrapolates while GPS is stale)
  src/geo/geo.dart          haversine, offsetLatLon, metresPerDegreeLat
  src/collections/          ring_buffer ([i]=NEWEST, getChronological(i)=oldest-first, newestFirst() lazy)
  workspaces/               layout_tree (KD-tree), workspace_models, widget_registry,
                            workspace_controller, workspace_grid, dashboard_screen, widgets/*
  flights/                  replay_controller, recordings_screen
  settings/                 launch_site_store, settings_screen
  components/               raw_byte_monitor (full-screen monospace, unscrollable)
```

- **TelemetryStore** (`telemetryStoreProvider`): single ingestion point, decodes
  packets, DR estimator, ring buffers (9000 ≈ 15 min @10 Hz), error counts,
  auto-reset on port change, skips live ingestion while replaying,
  `notifyThrottled()` (80 ms) for replay pumping. `TelemetryState.history` and
  `.deadReckoningHistory` are **live ring-buffer views** (zero-copy); iterate
  them, don't copy.
- **Dead reckoning is a gap filler, not a parallel track** (2026-09): DR points
  enter `deadReckoningHistory` only while GPS has been silent ≥1 s, at 1 Hz
  spacing; with a fresh fix nothing is computed (the fix is the estimate). A
  1 Hz wall-clock timer in the store keeps extrapolating from the last known
  velocity during total link loss (live only, not during replay).
  `DrPosition.atMs` carries the estimate time (used by the flight-3D merge).
- **Persisted keys** (shared_preferences): `trycatch.workspaces.v1`,
  `trycatch.launch_sites.v1`.

## 4. Workspace layout = KD-tree (hyprland-style)

`layout_tree.dart`: `SplitNode{id (stable — ratio updates are by id, not
identity), vertical, ratio, a, b}` | `LeafNode{widgetId, typeId}`. Every widget
type has a **pixel min size** (registry); `layoutTree()` clamps each split so
both subtrees keep their minimums. Ops (pure): `insertLeaf` (splits largest
leaf; orientation from last-known shape via `updateKnownRects` — the renderer
feeds it), `removeLeaf` (collapses), `swapLeaves` (drag-onto),
`treeFromOrder` (migration/factory), `SplitNode.flipOrientation` (user can
**double-click a divider in edit mode** to flip a split between horizontal
and vertical — via `workspaceProvider.toggleSplitOrientation`; orientation is
persisted in the tree JSON, so splits are not strictly alternating).
JSON: `{type:'split',id,vertical,ratio,a,b}` /
`{type:'leaf',widgetId,typeId}`; old grid `placements` JSON is migrated
(sorted y,x → balanced tree).

Controller (`workspaceProvider`, AsyncNotifier): addWidget / removeWidget /
swapWidgets / setRatio(nodeId) / setActive / create / duplicate / rename /
delete / resetToDefaults / persistActive(). Drag gestures mutate with
`persist: false` and call `persistActive()` on release.

Grid renders the tree (memoized by root identity + size), dividers are
positioned `MouseRegion`+`GestureDetector` **only in edit mode** (outside it
they are plain static lines — ratios are not editable during live viewing);
edit mode adds drag-to-swap (pointer badge + target highlight), a per-tile
**split button** (`Icons.call_split` → widget picker → `splitLeaf` splits that
specific tile, `addWidget(typeId, splitWidgetId:)`), and per-widget remove,
and wraps widget content in `AbsorbPointer`. Dashboard adds workspace
tabs (Ctrl+1..9, right-click menu, double-click rename), Edit layout toggle,
Add-widget picker (always enabled; `showWidgetPicker` is shared), Reset with
confirm dialog.

Widget registry = data-driven (11 widgets). Adding a widget = one class + one
descriptor entry (id, title, description, minSize px, builder).

## 5. Widgets (all content-only; grid wraps them in `AppCard(fillChild:true)`)

- **time_series_chart.dart — THE shared chart.** `TimeSeriesConfig{unit,
  series(List<SeriesSpec{label,color,value,dashed}>), window=60 s, yMin/yMax,
  showLegend, showLeftAxis}`. 200 ms ticker; "now" = wall clock live,
  `firstPacketMs + replay.positionMs` during replay. **Raw data, isCurved=false,
  no filtering** (decimation ≤400 pts, bucketed by *absolute* packet time so
  the sampled set is stable while the window slides — no flicker at the left
  edge). Y bounds snapped to 1-2-5 steps incl. zero baseline; flat data (hall
  on the pad) opens the axis around the value instead of a zero-height range
  (this was the `FlGridData.horizontalInterval couldn't be zero` crash).
  **Replay mode:** with ≥2 pre-decoded frames the chart switches to
  whole-flight view — x axis 0…duration counting up, y bounds fixed to the
  full recording (cached by frames-list identity). Area fill under
  single-series charts.
- Thin charts: altitude, velocity (horiz/vert-dashed/total), acceleration
  (horiz/total), battery (voltage readout + charged/under load/low pill @7.9/7.5 V),
  hall (big raw number + wire intact/broken pill, threshold 2700,
  `showLegend: false`). ALL share the chart.
- fsm_widget: responsive (fills the tile): current state large on top with
  glow dot + time-in-state, pipeline chips wrap below. stats_widget:
  responsive (fills the tile): MAX ALT + FROM SITE headline cards on top,
  GPS / dead-reckoning groups below (tinted cards, rows span full width,
  FittedBox scale-down at small sizes — no fixed design size).
- map_widget: OSM/Esri-satellite toggle, follow FAB, zoom ± FABs, GPS track
  (solid blue) vs DR track (dashed violet), site flag marker, legend overlay,
  plain attribution text. Polylines only rendered when >1 point (empty
  LatLngBounds crash guard).
- rocket_3d_widget: software renderer on vector_math (parametric mesh from
  `rocket_mesh.dart`: 20-seg body + cone + 3 double-sided fins + cap;
  perspective, painter's algorithm by view-space z, flat shading with camera
  headlight, hairline strokes against seams). Drag orbits; axis gizmo projects
  world XYZ **perspective-correctly** (axes pointing away are
  dimmed and shorten — they used to flip wildly near the view axis); the
  rocket-nose R vector was dropped (user request).
  parachute = `Icons.paragliding` overlay (drogue teal / main orange);
  `WaitingForData` when no frames.
- flight_3d_widget: 3D flight path on the same renderer approach. Metric scene
  (east/up/north metres, origin = launch site or first fix), trail = GPS fixes
  bucket-decimated + DR points interleaved by time, drop line under the rocket,
  gridded ground plane (1-2-5 spacing), launch-site flag + pad ring + label,
  altitude/downrange readout, chute icon. Cameras: chase rocket / orbit field
  (auto-rotates) / free orbit; drag orbits, wheel zooms.
- control_panel_widget: `RocketCommands` catalog — bytes are MADE-UP
  (`'TC' 0x54 0x43` + cmd + 0x00): arm 01, disarm 02, fire drogue 03,
  fire main 04, beep 05, reset FSM 06. Two-click confirm (3 s timeout), sent
  feedback, disabled when disconnected. **Must be aligned with real firmware.**

## 6. Replay & recordings

`replayProvider`: play(path) decodes trying framings **[53, 52]** (old 31-byte
→ `errorMsg` "Unsupported recording format"); the whole flight is also
pre-decoded into `ReplayState.frames` once so charts can fix their axes;
50 ms ticker ingests packets ≤ virtual clock × speed (MAX = dump all);
`seek()` replays 0→target through the store (keeps DR consistent); auto-pauses
at end. **While replaying the top bar replaces serial/recording groups with
the PlaybackBar** (play/pause, seek, speed, "Back to live"; turns green
"Replay finished — back to live" at the end). Recordings screen lists
`Documents/TryCatch/recordings/*.bin` with duration (chunk-header walk) and
delete; hitting replay there navigates to the dashboard automatically
(load errors stay on the recordings screen).

## 7. Raw monitor

Full-screen monospace hex, **unscrollable**: renders only the newest lines
that fit (line height 20 px, container padding reserved), drops the rest, and
centers the block in the leftover space. No header, no totals, no seq —
just `[time] hex · state · alt`.

## 8. Decisions & user preferences (important!)

- Wire format is a placeholder until the real firmware format exists; version
  byte + CRC keep it evolvable. Payload 52→53 change happened when hall became
  u16; old 52-byte recordings still replay via legacy decode.
- Layout must be tiling (KD-tree), everything fits the viewport, no page
  scroll, no holes, min sizes respected.
- Dead reckoning is computed **ground-side**, decoupled module (like serial).
- Charts display raw data — no smoothing/filtering; all share one code path.
- Keep the codebase modular/data-driven; one-file + one-registry-entry to add
  widgets; shared `TimeSeriesChart`.
- **Light mode only** (practical, sunlight); team color is pink `#FF00A1`
  (2026-09). Design direction picked: "D — Precision Light" from the
  `design_mockups/` HTML mockups (A dark was rejected; B2/C2 were the runners-up).
- **Do not start the app yourself** — the user runs it. Do not take
  screenshots; ask the user for screenshots/descriptions instead.
- Debug builds are janky; for smoothness checks suggest `flutter run -d
  windows --release`. Perf fixes so far: zero-copy ring-buffer history views,
  memoized tree layout.

## 9. State / next steps

- Analyzer clean, 60 tests green (`flutter test`). Nothing committed to git yet
  — the whole UI rework **including the Precision Light redesign** is
  uncommitted working-tree changes; consider a commit.
- 2026-09 redesign sweep awaiting user verification: segmented top bar cells,
  card header strips, pink accents everywhere (connect button, active toggles,
  drag handles, dividers while dragging, FABs, tab underline, launch-site
  flag, drag badge), mono micro-labels on stats/pills/legends/axes, FSM
  segmented pipeline chips, restyled recordings/settings/raw monitor. Run
  `flutter run -d windows --release` and check every screen.
- 2026-09 fix batch awaiting user verification: dividers only draggable in edit
  mode; hall-chart zero-interval crash; chart flicker once data reaches the
  left edge; replay charts (whole flight, fixed y bounds, 0-counting axis);
  axis gizmo while orbiting; DR only during GPS-stale gaps (note: the
  simulator always has a fix after cold start, so DR stays empty there by
  design — recordings with GPS dropouts will show it); raw monitor centering;
  replay auto-navigation; the new Flight 3D widget (in the Add-widget picker
  and the factory flight layout — existing persisted workspaces need
  "Add widget" or Reset to see it).
- Wait for user verification of: KD-tree editor feel, new rocket renderer,
  unified charts, top-bar playback, raw monitor.
- Possible future work: offline map tile cache; real firmware format swap-in;
  ground-side attitude estimation slot (`src/estimation/`) if firmware sends
  raw IMU only; serial port auto-reconnect; keyboard shortcuts polish;
  satellite imagery under the 3D flight view (the "Google Earth" wish).
