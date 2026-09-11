# TryCatchDart — Project Context & Agent Handoff

> Ground station for model rockets ("Testing in Production"). Flutter desktop
> app (Windows x86_64 + ARM64, Linux, macOS — primary dev target Windows),
> "Precision Light" UI. This document is the single source of truth for all
> agents. **Keep it current. If you change something architectural, update the
> relevant section before you hand off.**

---

## Part 1 — Multi-Agent Coordination

> **Read this first. It prevents agents from stepping on each other.**

### 1.1 Ownership map

Each agent working in parallel must claim an area and stay inside it.
Cross-area changes require explicit coordination (see §1.4).

| Area | Canonical paths | Pinning tests |
|---|---|---|
| **Wire / codec** | `packages/serial/lib/telemetry/`, `packages/serial/lib/io/` | `frame_codec_test`, `packet_parser_test`, `recorder_test`, `recording_header_test`, `file_parser_test` |
| **Core logic** | `lib/core/` | `dead_reckoning_test`, `ring_buffer_test`, `packet_rate_tracker_test`, `flight_events_test`, `highlights_test` |
| **State / providers** | `lib/state/` | `workspace_test`, `workspace_reorder_test`, `replay_seek_test`, `display_smoothing_test`, `replay_launch_site_test`, `launch_site_flow_test` |
| **Replay** | `lib/state/replay_controller.dart`, `lib/state/telemetry_store.dart` (replay paths) | `replay_seek_test`, `display_smoothing_test`, `mock_bq_test`, `flight_simulator_test` |
| **Map tile** | `lib/ui/tiles/map_tile.dart`, `lib/ui/tiles/shared/tile_io.dart`, `lib/ui/tiles/shared/offline_fallback_tiles.dart` | `map_track_test`, `map_tiles_test`, `map_follow_regression_test` |
| **3D / satellite tile** | `lib/ui/tiles/flight_3d_*.dart`, `lib/ui/tiles/shared/flight_3d_*`, `lib/ui/tiles/shared/satellite_ground.dart` | `flight_3d_scene_test`, `rocket_mesh_test`, `rocket_centering_test`, `sat_render_test`, `satellite_ground_test` |
| **Charts / tiles** | `lib/ui/tiles/` (non-3D, non-map) | `chart_touch_test`, `time_series_decimation_test`, `scroll_zoom_test`, `dead_reckoning_tile_test`, `events_tile_test`, `trim_chart_test` |
| **UI chrome** | `lib/ui/screens/`, `lib/ui/components/` | `top_bar_theme_test`, `brand_mark_theme_test`, `brand_navigates_home_test`, `link_stats_button_test`, `serial_controls_overflow_test`, `channel_health_test`, `channel_health_edit_mode_test`, `grid_render_test`, `tab_tooltip_semantics_test`, `flight_trim_test` |
| **Theme** | `lib/theme/` | `top_bar_theme_test`, `brand_mark_theme_test` |
| **Linux native shell** | `linux/runner/`, `linux/CMakeLists.txt`, `packaging/linux/` | (manual) |

**Shared / dangerous files — coordinate before touching:**
- `pubspec.yaml` / `pubspec.lock` — dep changes affect everyone; agree first.
- `lib/state/telemetry_store.dart` — touched by Wire, Core, State, and Replay agents.
- `lib/ui/tiles/shared/flight_3d_scene.dart` — used by both 3D tile and rocket mesh work.
- `packages/serial/lib/telemetry/frame_codec.dart` — single wire format; any change invalidates recordings.
- `analysis_options.yaml` — changing lint rules can fail the whole tree for other agents.

### 1.2 Before you start a task

1. **Read this file.** Skim sections relevant to your area.
2. **Check git status.** `git status` — the working tree must be clean.
   If there are uncommitted changes from a previous agent, **do not stash them blindly**.
   Read what they are. If they are in your area, commit or discard them with justification.
   If they are in another area, stop and report — do not absorb foreign work.
3. **Run the baseline.**
   ```powershell
   flutter analyze
   flutter test
   ```
   Record the number of passing tests. If the baseline is already red, **stop and report** — do not start work on a broken tree. You are not responsible for failures you did not introduce.
4. **Claim your area** — note in your task description which ownership-map area you are in.
5. **Create a branch** (optional but strongly recommended for anything beyond a one-file fix):
   ```powershell
   git switch -c agent/<area>/<short-description>
   ```

### 1.3 While you work

- **Stay in your area.** If you discover a bug outside your area that blocks you, open a note in the session log (Part 8) and ask for a separate agent to fix it.
- **Do not use `git stash`** to hide work. Stashed changes are invisible to other agents and can be overwritten silently. Commit with a clear WIP message instead, or discard explicitly.
- **Commit small and often.** One logical change per commit. This makes rebasing and conflict resolution tractable.
- **Do not run the app.** The app requires hardware or a mock port and a desktop session. Ask the user for screenshots/descriptions instead. Run `flutter test` and `flutter analyze` to verify.
- **Do not modify tests that were green before you started**, unless the test itself is what you were asked to fix. If a previously-green test now fails, see §1.5.

### 1.4 Cross-area changes

If your task genuinely requires touching another agent's area:

1. **Stop.** Do not proceed unilaterally.
2. **Document** what you need changed and why (in the session log Part 8 or a comment).
3. **Coordinate** — either the other agent makes the change, or you explicitly take over that area for this task (acknowledge the full area's pinning tests).
4. **Run the full pinning test suite** for every area you touched before handing off.

### 1.5 If a test you didn't touch is failing

> This is the most common source of confusion in parallel work.

**Triage checklist — run in order, stop when you find the cause:**

1. **Was it failing before you started?** Re-check the baseline you recorded in §1.2 step 3. If yes, it is not your fault — report it and move on.
2. **Did you touch a shared file?** (see §1.1 shared/dangerous list). Even a formatting change in `telemetry_store.dart` can affect tests in multiple areas.
3. **Is the failure in a test that pins a contract your code must satisfy?** e.g., if you changed the wire format, `frame_codec_test` will fail — that is expected and you own the fix.
4. **Is the failure transient?** Some widget tests are timing-sensitive. Run `flutter test <test_file>` in isolation before blaming your change.
5. **Is the failure in a FS-backed screen test?** `path_provider` and `Directory.list` stall permanently inside the fake-async zone (widget tests). These tests cannot be written as widget tests — that is a known Flutter limitation, not a bug in your code.
6. If none of the above apply: **do not touch the failing test**. Write a clear note in Part 8, commit your work, and hand off.

### 1.6 Before you hand off / finish

1. **`flutter analyze`** must be clean (zero issues).
2. **`flutter test`** must be green. The count must be ≥ the baseline you recorded. If you added tests, the count should be higher.
3. **Update Part 8 (session log)** with a concise entry: what changed, which tests were added/changed, the new passing count.
4. **Update the relevant technical section** (Parts 2–7) if you changed anything architectural.
5. Commit everything with a clear message. No WIP commits in a finished handoff.
6. If you branched, do not merge — leave the branch and note it in Part 8. The user decides when to merge.

---

## Part 2 — Stack & Conventions

### 2.1 Toolchain

- Flutter SDK ^3.13, installed at `C:\Users\wwwho\flutter`. Desktop shells for Windows, Linux, macOS.
- Always run with `--release` for evaluation — debug builds are janky and misrepresent performance.
- `flutter analyze` + `flutter test` are the only CI gates. Both must be green before any handoff.
- Current passing test count: **262** (last recorded green run — update this when you finish).

### 2.2 Dependencies (key constraints)

| Package | Version | Gotchas |
|---|---|---|
| Riverpod | 3, no codegen | `Notifier`/`AsyncNotifier`. Use `AsyncValue.value`, **not** `valueOrNull`. `ProviderScope.overrides` injects the worker isolate in `main`. |
| fl_chart | 1.2 | `SideTitleWidget(meta: meta, child:)`, `LineChart(duration: Duration.zero)`, `StrokePattern.dashed`, `BarAreaData`. `BorderSide.strokeAlignInside` is a `double`, not an enum. |
| flutter_map | 8.3 | + `latlong2`, `vector_math` (`transformed(Vector4)`, `transformed3(Vector3)`, `scaleByDouble(x,y,z,w)`). |
| tray_manager | 0.5.3 | Linux: still calls deprecated `app_indicator_new()`. `linux/CMakeLists.txt` suppresses `-Wno-deprecated-declarations` on the plugin target only (guarded by `if(TARGET …)`). Our own code keeps `-Werror`. |
| Others | — | `shared_preferences`, `path_provider`, `window_manager`, `flutter_libserialport`, local `packages/serial`. |

No router package (4 flat screens via enum provider). No `build_runner`/freezed.

### 2.3 Dark-mode const rule ⚠️

`AppColors` / `AppText.microLabel` / `AppText.monoValue` are **getters** that resolve the active palette at call time. **Never** hold them in a `const`, and **never** `const`-instantiate any widget that transitively reads them. `const AppShell` / `const TopBar` / `const`-screens froze whole subtrees across dark/light flips. Map tiles stay light in both modes.

### 2.4 Impeller / Windows-ARM64 blank-paint bug ⚠️

Per-card `BoxShadow` + `Clip.antiAlias` on grid tiles silently blanks the workspace grid — layout is correct, no exceptions thrown. Rules:
- `AppCard` has **no `boxShadow`** and uses `Clip.hardEdge`.
- Do not reintroduce either on grid tiles without testing on-device.
- Grid keeps dividers as invisible `Positioned` children in live mode so the Stack child count is identical in both edit and live modes.
- Nuclear fallback: `flutter::ImpellerSwitch::Disabled` in `windows/runner/flutter_window.cpp`.
- `Canvas.transform` perspective drapes also silently paint nothing on Impeller/OpenGLES — use the custom clip-space projection in the satellite tile instead.

### 2.5 Pointer input (desktop)

A precision-touchpad two-finger swipe arrives as `PointerPanZoom` events, **not** wheel scrolls. `flutter_map` ignores those for zoom; drag recognizers also ignore pure swipes. Every map/3D view must handle both paths:
- Wheel: `scrollWheelZoom` flag / `Listener.onPointerSignal`
- Trackpad swipe: explicit `onPointerPanZoomUpdate` handler

Map zooms with the wheel velocity, cursor-anchored via `focusedZoomCenter`, skipping updates that carry scale (flutter_map's pinch-zoom owns those). 3D shell + rocket tile zoom from swipe (`scrollZoomFactor`, ×1.1 per 120 units) and pinch, suppress drag-orbit while a trackpad gesture is active (a real press clears the flag). Pinned by `scroll_zoom_test.dart`.

### 2.6 Accessibility / AXTree

Windows desktop semantics are always on. Display-only readouts that repaint at telemetry rate must carry `ExcludeSemantics` to prevent AXTree spam. Policy:
- **ExcludeSemantics**: live text readouts inside `CenteredValue`, `ChartValueHeader`, `TimeSeriesChart`, channel charts, 3D readout, packet-rate + rec-timer + playhead clocks, battery discharge line, map legend/attribution.
- **Full semantics**: all interactive controls (buttons, chips, sliders, dropdowns, menus, fields, copy buttons).
- Adjacent bare tooltip anchors in one scrollable item merge in the AXTree (flutter/flutter#182444). Fix: `Semantics(container: true)` per anchor. Already applied to FSM/control grids. Every other list tooltip is button/InkWell-backed (own node) or single-per-item.

### 2.7 Theme

`lib/theme/`: white/dark cards (radius 12/8) on cool grey, hairline borders, monospace micro-labels (Consolas via `AppText`), team pink `#FF00A1` as the single accent (`pinkDeep` for text-safe accents; status stays green/amber/red). `AppCard` header = pink dot + mono uppercase label + hairline divider (**no tinted band**). `StatusPill` = mono uppercase stadium. Series colors: baro alt = pink, GPS/horiz = blue, DR/battery = violet, vert = green, accel = amber. Default system font (user declined bundling Inter).

### 2.8 Linux native shell

`linux/runner/my_application.cc`: `GtkHeaderBar` only on GNOME-like desktops (env `*DESKTOP*` has gnome/unity/pantheon/budgie, or X11 WM is GNOME Shell/Mutter); KDE Plasma and all other WMs fall back to a traditional title bar. Native title is `TryCatch`. X11 window icon resolves `linux/assets/icon.png` (dev) then `assets/icon.png` (bundle). On Wayland the icon comes from the hicolor theme via the `.desktop` entry (full 16–512 px set in `packaging/linux/icons/hicolor/*/apps/com.krychlic.trycatch.png`). `StartupWMClass=com.krychlic.trycatch` must equal the Wayland app_id. For `flutter run`, run `tool/install-linux-desktop-entry.sh` first.

---

## Part 3 — Wire Format & Serial Package

`packages/serial/` — single wire format, no versioning. Changing it invalidates all existing recordings and must be coordinated across Wire, State, and Replay agents.

### 3.1 Frame format

Framing: sync `0xAA55` + payload 52 bytes (incl. trailing CRC16). `telemetry/frame_codec.dart` `TelemetryLayout`, big-endian:

```
0  flags u8 (bit0 gpsFix, bit1 gpsFix3d)
1  seq u16              3  gpsLat i32 1e-7deg     7  gpsLon i32 1e-7deg
11 gpsAlt i32 cm        15 baroAlt i32 cm       19 velN i16 cm/s   21 velE   23 velD
25 accelX/Y/Z i16 mg    31 gyroX/Y/Z i16 centidps (±327 dps)
37 heading u16 centideg 39 roll i16 centideg 41 pitch 43 yaw
45 battery u16 mV       47 hall u16 raw (~2500 intact / ~2950 broken)
49 fsmState u8          50 crc16-ccitt (init 0xFFFF, poly 0x1021)
```

Units: WGS84 deg, metres, NED velocity (Down+), body-frame specific force (+9.81 at rest), gyro deg/s, rocket-oriented attitude (pitch = tilt from vertical, yaw = compass heading, roll = spin). CRC check vector `"123456789"` → `0x29B1`. `PacketParser` has fixed framing.

### 3.2 FSM states & airframe flags

`FsmState` ids: idle 0, armed 1, ascent 2, apogee 3, parachute 4, landed 5, debug-unlocked 6, debug-locked 7, unknown 255.

Airframe flags (derived from FSM state):
- `hasNosecone`: true on idle/armed/ascent/debug-locked (nose-cone tile LOCKED green), false on apogee/parachute/landed/debug-unlocked (UNLOCKED red).
- `hasParachute`: deployed on parachute + landed (retained from the previous parachute state).
- `showsParachute`: renders the canopy on parachute only.

### 3.3 Recording file format

`io/recording_file.dart`: 108-byte header + chunk stream. Header (big-endian): magic `TCRC` u32, payloadLength u16 (=52), flags u16, start/end micros i64, packetCount u64, max baro/speed/accel f32, launch lat/lon i32 1e-7deg, launch MSL f32, launch name 48 B UTF-8 NUL-padded, CRC16 over bytes 0..103, reserved.

**Launch site is mandatory.** `start()` requires a site (provisional header already carries it, so even crash-interrupted files are valid). `stop()` finalizes via `finalizeRecordingFile` (never throws; idempotent). No first-GPS-fix fallback — siteless files are rejected everywhere. Magic-less files are rejected. Chunks carry a 12-byte header (i64 µs + u32 len).

> ⚠️ `crc_real_flight.bin` on disk is stale (pre-dates de-versioning). Re-convert from `flight_data.js` before use.

### 3.4 Mock simulator

`FlightSimulator` (seeded): coldStart 2 s → pad 6 s (armed after 2 s) → boost 2.8 s @55 m/s² → coast (drag 4e-4) → apogee ~1058 m + hall break → drogue (~40 m/s) → main @150 m (~6 m/s) → landed (pitch 85°). GPS random-walk, eastward wind drift, battery 8.4 V −2.5 mV/s. Prague pad.

`MockSerialPort` (`MOCK`): 10 Hz + 20 s interference cycle (12 s clean / 4 s light / 4 s heavy + bit-flipped clones) — sweeps all channel-health verdicts.

`MockBqSerialPort` (`MOCK-BQ`): same flight + interference, drops link completely for ~5 s every ~15 s — exercises DR gap filling and stale-link UI.

Worker isolate: typed commands (Connect/Disconnect/ListPorts/StartRecording/StopRecording/SendBytes) and events (Packet/PortList/Status/Error) over `SendPort`.

---

## Part 4 — App Architecture

```
lib/
  main.dart          worker spawn → ProviderScope override → AppShell
  ui/screens/        AppShell, router, TopBar, dashboard (tabs + grid),
                     recordings (+orbit previews), monitor, settings
  ui/components/     BrandMark, SerialControls, LinkStatsButton,
                     RecordingControls, PlaybackBar,
                     AppCard, StatusPill, ToolFab, WaitingForData,
                     CenteredValue, CopyButton, FlightEventDot,
                     FlightEventStyle
    ui/tiles/        18 telemetry tiles (incl. channel health and events);
                     shared/ = TimeSeriesChart, ChartValueHeader,
                     Flight3dShell, flight scene/painters/shell,
                     rocket mesh, orbit camera, map/satellite tile I/O
  state/             telemetry_store (ingestion point),
                     telemetry_provider (streams + serial config),
                     replay_controller, tile_registry, layout_tree,
                     workspace_models, workspace_controller,
                     launch_site_store, router, orbit camera
  services/          flight_trim, prefs_keys
  core/              pure logic (no Flutter/Riverpod): geo, dead_reckoning,
                     ring_buffer, channel_health, packet_rate_tracker,
                     format, flight_events
  theme/             app_colors (palette + AppThemeMode + tokens), app_theme
packages/serial/     framing, codec, worker isolate, mock simulator
```

### 4.1 TelemetryStore

Decode, DR estimator, ring buffers (9000 ≈ 15 min @10 Hz), auto-reset on port change, skips live ingestion while replaying, 80 ms throttle. `history`/`deadReckoningHistory` are zero-copy live views. DR is gap-filler only: points enter history while GPS is silent ≥1 s (1 Hz); a 1 Hz timer extrapolates through total link loss (live only). `drStaleMs` (1000) is the shared stale threshold.

Persisted keys (`services/prefs_keys.dart`, no version suffixes): `trycatch.workspaces`, `trycatch.launch_sites`, `trycatch.dark_mode`.

### 4.2 Known weak points (out of scope — do not fix without a dedicated task)

- `AppThemeMode` singleton lives outside Riverpod.
- `ref.listen` in `build` (channel tile/pill, packet-rate tracker).
- `ref.read(workspaceProvider).value` staleness in some places.
- `TelemetryStore` is a god-store with bidirectional `ReplayController` coupling (sync `seek()` janks large files).
- Global orbit camera shared across 3D tiles.
- `SerialConfigNotifier` mixes UI/IO/FS concerns.

---

## Part 5 — Workspace Layout (KD-tree)

`SplitNode{id (stable), vertical, ratio, a, b}` | `LeafNode{tileId, tileType}`. Every tile type has a pixel min size; `layoutTree()` clamps splits to minimums.

Pure ops: `insertLeaf` (splits largest leaf, orientation from last-known shape), `removeLeaf`, `swapLeaves`, `treeFromOrder` (factory default), `SplitNode.flipOrientation` (double-click a divider in edit mode).

JSON: `{type:'split',id,vertical,ratio,a,b}` / `{type:'leaf',tileId,tileType}`.

Controller: addTile/removeTile/swapTiles/setRatio/setActive/create/duplicate/rename/delete/resetToDefaults/persistActive. Drags mutate with `persist:false`, persist on release. Grid memoizes layout by root identity + size.

Edit mode: dividers draggable, drag-to-swap, per-tile split/remove, tile content in `AbsorbPointer`. Dashboard: tabs (Ctrl+1..9, right-click menu, tooltips), Edit layout toggle, Add-tile picker, Reset with confirm.

Tile registry is data-driven — new tile = one class + one descriptor entry (id, title, description, minSize, immersive, builder).

---

## Part 6 — Tiles Reference

### 6.1 Shared pieces

- **`TimeSeriesChart`**: raw data, no smoothing. 60 s rolling window live; replay shows whole flight (played full opacity + remainder 25%). 1-2-5 y steps with zero baseline. Flat data opens the axis (was the `horizontalInterval = 0` crash). Decimation ≤400 pts by absolute packet time. Legend collapses under ~120 px tile height.
- **`ChartValueHeader`**: big readout for battery/hall.
- **`CenteredValue`**: centred headline + sublabel. Pins a tight `LayoutBuilder` box so `FittedBox` actually shrinks.
- **`Flight3dShell`**: camera-state mixin + gesture canvas / tool column / readout.
- **`tile_io.dart`**: Esri URLs, download, image check, shared disk cache.

### 6.2 Charts

Thin wrappers over `TimeSeriesChart`: altitude, velocity (horiz/vert-dashed/total), acceleration (vert-dashed/total), battery (+discharge rate line, hidden when short), hall (no legend, threshold 2700 colors the readout).

### 6.3 Non-chart info tiles

- **FSM**: big state + time-in-state (1 s ticker; replay uses playhead). Progress bar + pipeline/debug chip grids. Two-click send mirrors the control panel.
- **Max alt**: peak + NOW.
- **Nose cone** (`nosecone`, legacy id `parachute` still resolves): padlock icon + LOCKED (green) / UNLOCKED (red) from `hasNosecone`.
- **GPS position** (`stats`): large coordinates, one `·`-joined line (altitude + drift), fix-status footer, copy + QR-code actions.
- **Dead reckoning** (`dead_reckoning`, live only): link-healthy placeholder while packets flow; shows extrapolated coordinates on packet loss. Disabled during replay. Both share `PositionReadout`.
- **Highlights** (`highlights`): session extremes — max ascent/descent velocity, top speed (Mach), max acceleration (G). Replay-only third row: total drift + max altitude. Pinned by `highlights_test.dart`.
- **Events** (`events`): newest-first log. Live rows read "Launch — 12 s ago" (1 s ticker). Replay rows read "Launch — at 1:23" and tap to seek; future events dimmed.
- **Control panel**: `RocketCommands` catalog — bytes are **MADE-UP and must be aligned with real firmware before flight**. Two-click confirm (3 s). Disabled while disconnected or replaying.

### 6.4 Map tile

Immersive. Esri street / satellite (overzoom past 18). 1 GB disk cache. Precache zooms 13–17 ~1 km around saved sites. GPS solid blue vs per-gap dashed violet DR. Follow/satellite/zoom ToolFabs. `TileDisplay.instantaneous()` on both tile layers. Per-layer background colors (`satelliteMapBackground` near-black, `streetMapBackground` pale paper). Cropped fallback tiles memoized in 128-entry LRU `CroppedTileCache`.

### 6.5 3D tiles

All immersive. Metric scene east/up/south metres, origin = site or first fix. GPS trail only, DR as single violet point. Drop line, 1-2-5 ground grid with N/E labels. N/E/U compass. Chase/orbit-field/launch-pad/free cameras (80° cap). Wheel zoom, double-tap reset. World frame X east / Y up / Z south (right-handed; locked by `flight_3d_scene_test.dart`).

Satellite tile drapes Esri imagery as a screen-space mesh (one node per ~21 px ray-cast; parent-tile fallback; ≥5 km²; failures uncached + 15 s backoff) with procedural sky. **Never** `Canvas.transform` perspective drape — silently paints nothing on Impeller/OpenGLES.

**Performance** (`_paintMeshTier`): indexed drawing (up to 5× fewer vertex submissions), sub-pixel pad tier culling, quad-level frustum culling, static `Float32List` scratch buffers, inlined color caching, lazy `meshUvs`. 60-frame benchmark: 3,489 ms → 1,219 ms (median 57.7 → 20.2 ms).

**Perspective distortion**: adaptive 4D clip-space sub-tessellation in `emitTri` when `w_max > w_min * 1.5`. Mean error: 3.012 → 1.308.

**Depth ordering**: view-dependent far-to-near traversal (`terrainTierDrawOrder`). Pinned by `satellite_ground_test.dart` + `sat_render_test.dart`.

### 6.6 Top bar

Fixed-width skeleton (nothing shifts in any state). Slots: brand · link group (port dropdown incl. Rescan + Connect, link-stats button) · hairline · launch-site button · session (Record) · menu.

Link-stats button: left half = live pkt/s decaying to "N s ago" past 2 s liveness window; right half = unknown B/s. Color = max(packet severity, congestion severity). No packets within 2 s → red. Neutral only before any data ever arrived.

Launch-site button (flag + site name, amber SET SITE when unset): preset list (tap selects), manual entry, save-current-rocket-position. A site is always selected — no Clear; deleting active preset falls through. Record stays disabled until a site is set. Reset is in the menu (confirm dialog, disabled without data or during replay).

Replay: REPLAY badge + filename + play + time + flexible slider + speed popup + Back to live.

### 6.7 Channel health

Verdicts on unknown B/s: clear <50, activity <400, else interference. Screen = verdict banner + chart card + 3 key numbers. Dashboard tile = compact verdict row + rolling/replay chart. Top-bar button always shows pkt/s + unknown B/s regardless of connection state.

### 6.8 Replay timeline events

`FlightEventType` carries label + matching `from`/`to` states + `transitionLabel`. Detection in `core/flight_events.dart`. Icon + palette color in `ui/components/flight_event_style.dart` + shared `FlightEventDot`. Events: launch, apogee, parachute, touchdown. Dots dim until playhead reaches them; tapping seeks. Markers that would overlap spread into lanes (`placeFlightEvents`, greedy, 16 px targets). Slider theme pinned (4 px track, r10 thumb, r24 overlay — M3 defaults), fixing thumb travel to 24..width-24.

---

## Part 7 — Replay & Recordings

### 7.1 Replay

`replayProvider.play(path)`: parses (valid header required), stores header site. Whole flight pre-decoded once for fixed chart axes. 50 ms ticker × speed (MAX = dump). `seek()` is binary search + forward-delta bulk ingest (`TelemetryStore.ingestPackets`, one state rebuild). Auto-pauses at end. No DR during replay.

Display smoothing (replay-only, toggle in playback bar, default on): 3D trail uses centered ±25-packet moving average; attitude from averaged specific-force vector. File, charts, map stay raw. `buildReplayScene` over full pre-decoded frames (smooth-then-decimate with ±25 lookahead). Pinned by `display_smoothing_test.dart` + `replay_seek_test.dart`.

### 7.2 Recordings screen

Stat-first scan (108-byte header) + per-card concurrent preview decode (session cache by path+size+mtime). Video-style cards: whole 200 px preview is the tap target, pink center play button, primary border while loaded, header `…` menu for trim/extract-site/delete, extent 284. `TrimChart` renders `FlightEventDot`s on the altitude curve (x from flight-clock fraction, y from nearest decimated profile value, downward de-collision, dimming for cut markers).

### 7.3 Factory workspaces

- **Flight**: default live view — highlights, FSM, charts, map, 3D, channel health.
- **Prep**: pre-flight check — channel health prominent.
- **Recovery**: live DR tile.
- **Replay**: no control panel / dead reckoning.

---

## Part 8 — Session Log

> **Agents: append a new entry here for every significant session. Keep it terse but complete: what changed, which files, which tests added/changed, new passing count.**

---

### 2026-09 (initial sessions)

- Structure refactor: de-versioned wire (52 B) + header (108 B). Dropped legacy decoders, migrations, converter. Extracted shared UI. `widget→tile` rename.
- UI/UX pass: dropped pressure; fixed dark-mode leaks; immersive map/3D; responsive shedding.
- Overflow pass: bounded `CenteredValue`; dropped battery/hall pills; topbar regrouped + REPLAY badge.
- Topbar rethink: rescan folded into port dropdown, Reset moved to menu, fixed-width skeleton, replay slider single Expanded. Channel screen rewritten in plain language.
- AXTree spam fix: `ExcludeSemantics` on display-only live readouts; `Semantics(container:true)` per bare tooltip anchor (flutter/flutter#182444). Replay filename badge hoisted behind path-only watch.
- Launch-site flow redo (saved-only): store normalizes on load, "Use without saving" removed. Fixed settings dropdown assertion crash. Port-switcher overflow fixed.
- Channel screen: TOTAL series dropped; FSM debug states always render (arithmetic fit check). BrandMark uses `assets/icon.png`; de-consted TopBar wrappers.
- Sites dialog redo: saved list, Add on top. Sites removed from settings. `tileCacheCoverage` probes exact precache URL set.
- Mandatory launch site: `select()` non-nullable; `LaunchSiteButton` in topbar; Record disabled without site.
- Linux tray fix: per-call guards; `setTitle` on Linux; `popUpContextMenu` skipped; icon resolves to absolute path.
- Real flight converted: `Documents/TryCatch/recordings/flightlog_tcrc.bin` (26,214 packets, ~17.5 min, LKMK 2026-07-10, Prague pad, MSL 403 m).
- Replay display smoothing + seek performance: binary search + bulk ingest `seek()`; 50 ms ticker batches. **182 green.**
- Replay 3D follow-up: shared smoothing for rocket + trail (`buildReplayScene`); launch-pad camera; play/pause via `ReplayController.toggle()`. **182 green.**
- 2D map performance: skeleton no longer subscribes to telemetry; leaf consumers on narrow version selector; `ref.listen` for follow; stride-decimation ≤1500 GPS pts; O(history+dr) DR segments; `TileDisplay.instantaneous()`. **247 green.**
- 2D map white-flash + crop cache: per-layer background colors; 128-entry LRU `CroppedTileCache`. **262 green.**
- Replay timeline event markers: clickable milestone dots, pure `core/flight_events.dart`, `replayFlightEventsProvider`, `placeFlightEvents` lane algorithm, slider theme pinned.
- `FlightEventType` data-driven; `events` tile: newest-first log, live ages, replay tap-to-seek.
- Recorded-flight card redesign + trim event markers: video-style cards; `TrimChart` with `FlightEventDot`s.
- Satellite 3D depth + perspective + performance fixes: far-to-near traversal, clip-space sub-tessellation, indexed drawing, culling, static scratch buffers. **262 green.**

---

## Part 9 — Design Decisions

- Wire format is a placeholder; CRC keeps it honest. Single format, no versioning — when real firmware lands, replace the layout wholesale.
- Tiling only: everything fits the viewport, no page scroll, no holes.
- Charts show raw data, one shared code path. Modular/data-driven tiles.
- Debug builds are janky — evaluate with `flutter run -d <os> --release`.
- **Do not start the app yourself.** Ask the user for screenshots/descriptions.
- FS-backed screen widget tests are impossible: `initState` always runs in the fake-async zone where `path_provider` + `Directory.list` stall permanently.
- AXTree quirk: on mass tree churn (e.g. RESET), the Windows accessibility bridge can spam even with `ExcludeSemantics`. Suspect hover+rebuild overlay dynamics or teardown races; check whether Narrator/a screen reader is running.
