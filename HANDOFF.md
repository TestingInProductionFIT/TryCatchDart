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
- Analyzer must stay clean; `flutter test` green (111 at last green run; see §9 — serial refactor currently breaks compilation).

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
- `FsmState` ids (wire v2): idle 0, armed 1, ascent 2, apogee 3,
  parachute 4, landed 5, debug-unlocked 6, debug-locked 7, unknown 255.
  Each state carries its airframe config (`hasNosecone`: idle/armed/ascent/
  debug-locked; `hasParachute`: parachute only) — the 3D views render from
  these flags. v1 payloads (same layout, old ids) still decode with the
  state translated (`fromV1Id`: boost/coast→ascent, apogee→apogee,
  drogue/main→parachute, landed→landed, fault→unknown).
- `FrameCodec.decode` auto-detects generation by length: 53 = current,
  **52 = legacy** (hall was u8 0/1@48, fsm@49, crc@50; mapped to 2500/2950).
  The ancient **31-byte format is random bytes, unsupported** (no CRC).
- CRC16-CCITT check vector: `"123456789"` → 0x29B1.
- `PacketParser(payloadLength: …)` — framing parametrizable for streams;
  file framing always comes from the v1 header.
- **Recording file format v1** (`packages/serial/lib/io/recording_file.dart`,
  2026-09): 112-byte header + the historical chunk stream. Header (all
  big-endian): magic `TCRC` u32, version u16 (=1), headerLength u16 (=112),
  payloadLength u16 (53/52, else 0 = probe), flags u16 (bit0 launch site,
  bit1 stats), start/end micros i64, packetCount u64, max baro/speed/accel
  f32, launch lat/lon i32 1e-7deg, launch MSL f32, launch name 48 B UTF-8
  NUL-padded (rune-safe truncated), CRC16-CCITT over bytes 0..107, reserved.
  `Recorder.stop` prepends it (launch = selected site, else first 3D fix;
  stats from a decode pass; never throws — on failure the body is left
  headerless). Readers require a valid header (framing/stats trusted only
  on valid CRC); headerless bodies are rejected everywhere except
  `finalizeRecordingFile`, which upgrades them in place (also used by trim
  and once for the pre-v1 capture already on disk).
- **FlightSimulator** (`telemetry/flight_simulator.dart`, seeded/deterministic):
  coldStart 2 s (no fix) → pad 6 s (armed after 2 s) → boost 2.8 s @ 55 m/s² →
  coast (drag 4e-4) → apogee ~1058 m + hall break → drogue (~40 m/s) →
  main @150 m (~6 m/s, chute accel clamped 40 m/s²) → landed (pitch 85°).
  Internal phases keep those names; the reported wire states collapse them:
  boost/coast→ascent, drogue/main→parachute (idle/armed/apogee/landed direct).
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

Widget registry = data-driven (12 widgets). Adding a widget = one class + one
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
  full recording (cached by frames-list identity), played segment full
  opacity + not-yet-played remainder at 25% alpha (same hue, no area fill).
  Area fill under single-series played segment only. 3D trail stays
  played-only (no future preview there).
- Thin charts: altitude, pressure (static hPa derived from baro alt via ISA,
  anchored at the selected site's MSL), velocity (horiz/vert-dashed/total), acceleration
  (horiz/total), battery (voltage readout + charged/under load/low pill @7.9/7.5 V),
  hall (big raw number + wire intact/broken pill, threshold 2700,
  `showLegend: false`). ALL share the chart.
- fsm_widget: current state fills the tile (bigger name, centred both ways,
  time-in-state under it, no dot), pipeline grid + progress bar pinned to the
  bottom; `WaitingForData` when empty. max_altitude_widget: same centred
  language (big max, small NOW under it).
- map_widget (`map_tiles.dart`): street = Esri World Street Map (bright,
  worldwide, no key — OSM-FR renders patchy 404s and OSM.org is
  policy-restricted), satellite = Esri (overzoom past native 18 → no blanks);
  both ride
  flutter_map's built-in 1 GB disk cache, and `precacheLaunchSites`
  (zooms 13–17, ~1 km radius, same URL keys incl. subdomain rotation) fills it
  around saved sites — auto on preset save, manual Preload button in settings
  with progress. DR freezes at the touchdown floor (lowest fix − 2 m) with
  zeroed velocity — the frozen point is the landing estimate; a fresh
  airborne fix unfreezes. FSM time-in-state ticks via a 1 s ticker past the
  last frame when the link is silent (live only — replay uses the playhead,
  wall clock would be hours off). Rocket livery: pink body, black nose
  tip + fin cage + cap, 4 fins. Workspace tabs rename via right-click menu
  only (no double-click); top bar RESET cell resets the flight context. OSM/Esri-satellite toggle, follow FAB, zoom ± FABs, GPS track
  (solid blue) vs per-gap DR segments (dashed violet, each rooted at its last
  known fix; live-only — hidden + legend row hidden during replay),
  site flag marker, legend overlay, plain attribution text. Polylines only
  rendered when >1 point (empty LatLngBounds crash guard). DR marker follows
  the store's extrapolated position, so a silent link shows the violet
  estimate drifting.
- stats_widget (title **Position**, centred cards like FSM/max-alt): GPS card
  (big coords, alt + from-site line, COPY button writing plain `lat, lon` to
  the clipboard); DR card the same. Replay shows the GPS card only. DR card
  reads "extrapolating" + GPS "STALE" on a silent link; DR alt clamps at the
  site MSL.
  max_altitude_widget: big peak value centred (no headline — the card header
  says it) + small NOW under it, pink.
- rocket_3d_widget: software renderer on vector_math (parametric mesh:
  pink tube, black ogive nose tip, black fin cage (longer than the fins) +
  cap, 4 double-sided fins; tube butts onto the cage with no overlapping
  shells; fin sheets are view-culled so the coplanar pair can't flicker);
  perspective, painter's algorithm by view-space z with mesh-order tiebreak +
  degenerate-triangle skip, flat shading with camera
  headlight, hairline strokes against seams). Drag orbits the shared camera;
  corner compass shows
  N/E/U in the flight view's colours (E amber, U green, N blue — same world:
  X east, Y up, Z south, so both 3D views agree); axes pointing away are
  dimmed and shorten.
  Airframe config comes from the FSM state flags (`hasNosecone` on
  idle/armed/ascent/debug-locked, `hasParachute` on parachute only): the
  cone hides from apogee on, the red/white canopy hangs above the open
  tube under parachute. `WaitingForData` when no frames.
- flight_3d_widget: 3D flight path on the same renderer approach. Metric scene
  (east/up/south metres, origin = launch site or first fix), trail = GPS fixes
  bucket-decimated only (DR renders as a single violet ring+dot at the rocket,
  never a trail), drop line under the rocket,
  gridded ground plane (1-2-5 spacing) with projected N (+Z, blue) / E (+X,
  amber) ground labels, corner N/E/U compass gizmo derived from the live view
  matrix (dimmed when pointing away — rotates together with the scene),
  launch-site flag + pad ring + label,
  altitude/downrange readout, chute icon. Cameras: chase rocket / orbit field
  (auto-rotates) / free orbit; drag orbits (rotation kept across mode
  switches), wheel zooms (scroll up = zoom in), +/− buttons, double-tap
  resets zoom; switching modes resets zoom to 1×. All three 3D views
  (rocket, flight, satellite) share `orbitCameraProvider` angles — dragging
  one rotates all; zoom/mode stay local. Elevation capped at 80°
  (straight-down is degenerate for an up-vector orbit camera — a map-style
  N-up/E-right reading is geometrically impossible there for a true
  perspective camera, so it is not offered).
  Shows the pad scene immediately (rocket at site + baro alt before first fix).
  A silent link (>1 s no packets, `TelemetryStore.drStaleMs`) moves the rocket
  to the violet DR estimate, like a stale fix does.
- flight_3d_widget + flight_3d_satellite_widget share `flight_3d_common.dart`
  (scene, cameras, painters, N/E/U compass). Satellite drapes Esri World
  Imagery (`satellite_ground.dart`: slippy fetch/stitch/cache, drawVertices
  perspective drape, plain fallback offline, Esri credit) around the anchor;
  ~1280 px across at zoom ≤19 with parent-tile fallback for missing levels.
  Imagery goes through flutter_map's shared disk cache, so settings precache
  warms the 3D view too (and the 3D view backfills it). Always renders
  ≥5 km² (`satMinHalfMeters`). Failures yield `null` (plain-ground fallback)
  and are NOT cached, so later calls retry; the widget also retries
  imageless fetches with a 15 s backoff. The drape is a screen-space mesh:
  one node per ~21 px ray-cast onto the ground plane (`rayGroundHit`,
  tested) for exact UVs, so triangles are small on screen by construction
  and affine UV interpolation cannot twist — world-space subdivision could
  never promise that (cells near the camera project huge; that was the
  close-to-ground twisting). Rays missing the plane (sky) or landing outside
  the patch (far terrain shows through) subdivide to pin the boundary, then
  drop. Single path every frame, no fitting, nothing to flap between. This
  deliberately avoids `Canvas.transform` with a perspective matrix: that
  path silently paints nothing on Impeller/OpenGLES (the pre-fix flicker was
  the renderer flapping between mesh frames showing imagery and transform
  frames drawing blank; the sky-bleed was the unclipped transform draw
  mirroring behind-camera ground above the horizon). Do not reintroduce a
  transform-based drape without testing on-device. No grid lines on imagery
  (labels stay); fully-behind views fall back to the plain ground. Plain
  Flight 3D
  deliberately has no sky (as-was); satellite keeps the procedural 3-stop
  sky + huge far ring (45 km, past the horizon) tinted from the patch's mean
  imagery color (`averageColor`, so fields stay green and cities stay grey)
  with a subtle horizon haze band. All world
  lines use clip-space near-plane clipping, so receding lines survive low
  camera angles.
- **World frame is X east / Y up / Z south (E×U=S, right-handed).** +Z north
  was left-handed and mirrored east/west on screen; `orientationMatrix` now
  yields a proper rotation (back = right×nose) with matching compass
  (nose→−Z on yaw 0, +X on yaw 90). Locked by `flight_3d_scene_test.dart`.
- parachute_widget: centred icon + label (OPEN orange / STOWED faint),
  in Flight/Prep/Replay factory layouts.
- Top bar: no micro-labels; link is one box (borderless dropdown, green port
  name when connected, fixed 104+104 skeleton); fixed 32px hamburger;
  RESET cell; shared `formatMinSec` with playback/recordings/trim.
- control_panel_widget: icon-over-label centred tiles (min 54px rows);
  `RocketCommands` catalog — bytes are MADE-UP
  (`'TC' 0x54 0x43` + cmd + 0x00): arm 01, disarm 02, fire chute 03
  (04 retired with the drogue/main split), beep 05, reset FSM 06.
  Two-click confirm (3 s timeout), sent
  feedback, disabled when disconnected or during replay (placeholder tile).
  **Must be aligned with real firmware.**

## 6. Replay & recordings

`replayProvider`: play(path) parses the v1 recording (`FileParser` requires
a valid header and treats its framing as authoritative; headerless files
hit the "expected a v1 file" error) and stores the header's launch site on
the state; while such a replay is active the map flag, 3D origin,
from-site distances and pressure reference all anchor to the file's site
(`effectiveLaunchSiteProvider` — file site wins, else the selected site).
The whole flight is also
pre-decoded into `ReplayState.frames` once so charts can fix their axes;
50 ms ticker ingests packets ≤ virtual clock × speed (MAX = dump all);
`seek()` replays 0→target through the store; auto-pauses
at end. DR is disabled during replay (store skips the estimator, map/3D hide
DR, position shows the GPS card only). **While replaying the top bar replaces serial/recording groups with
the PlaybackBar** (play/pause, seek, speed, "Back to live"; turns green
"Replay finished — back to live" at the end). Recordings screen lists
`Documents/TryCatch/recordings/*.bin` with duration (chunk-header walk) and
delete; hitting replay there switches to the **Replay** workspace (if present)
and navigates to the dashboard automatically
(load errors stay on the recordings screen). Factory workspaces: Flight view,
Prep, Replay (large Flight 3D left + map/charts/position right, no control
panel); persisted states migrate by appending Replay when missing.
Recordings screen: responsive card grid with orbiting 3D track previews
(`orbit_preview.dart`: own equirectangular project + orbit camera, no tiles
so cards stay cheap/offline; sparkline fallback without fixes), stats
(duration, packets, max alt, size, date — all three come straight from the
112-byte header during the scan), open-folder shortcut, Trim dialog
with altitude graph + kept-window highlight saving a time slice as a new
`.bin` (`flight_trim.dart`, tested — the clip gets a fresh header with kept
stats and the source's launch site). Chunks are raw stream fragments, so
previews decode via `decodeRecordingFrames` (PacketParser 53→52 fallback —
decoding chunks directly yields nothing and a flat preview); each card
decodes its own file concurrently after the stat-only scan renders the grid
(spinner meanwhile), with a session cache (path+size+mtime) so refreshes
skip unchanged files; the trim dialog self-heals a stale profile on open.
Imported real flight: `Documents/TryCatch/recordings/crc_real_flight.bin`
(converted 2026-09 from the old web visualizer
`CRCVisualization/flight_data.js` via `tools/convert_crc_flight.py` —
3660 packets @25 Hz, 146.36 s, apogee 488.6 m, launch ~49.79945 N 16.69290 E;
re-emitted 2026-09 with a v1 header carrying those stats + the pad as the
launch site, verified through the real header/chunk/CRC path).
Mapping: alt→baro+GPS alt, vel(up+)→velD, velN/E from GPS-track derivative
(±1 s window, old GPS is ~1 Hz vs 25 Hz telemetry), accel(G)→m/s²,
ARMED→armed, FLIGHT pre-apogee→ascent, apogee + post-apogee FLIGHT→apogee,
CHUTE_DEPLOYED→parachute, touchdown (alt≤0.5 m, ~t=140 s)→landed, wire v2,
hall 2500→2950 at chute deploy, heading/yaw = course-over-ground, pitch 85
when landed; pressure/tribo/ky/temp dropped (no wire fields — the old tribo
chart has no counterpart widget). Battery kept as 1S ~4 V, so the battery
widget reads LOW against its 2S thresholds. Verified 3660/3660 decode via
the real FileParser/PacketParser/FrameCodec path. Cards use fixed heights only (an
Expanded child explodes on the grid's unbounded height pass). Raw monitor:
newest packets on top, top-anchored, max-1100 block centred. RESET unfocuses
first (Windows AXTree engine quirk on mass tree churn); SwitchListTile got
its own Material (ListTile splash assert).

## 7. Raw monitor

Full-screen monospace hex, **unscrollable**: renders only the newest lines
that fit (line height 20 px, container padding reserved), drops the rest, and
centers the block in the leftover space. No header, no totals, no seq —
just `[time] hex · state · alt`.

## 8. Decisions & user preferences (important!)

- Wire format is a placeholder until the real firmware format exists; version
  byte + CRC keep it evolvable. Payload 52→53 change happened when hall became
  u16; old 52-byte payloads still decode. Wire v2 (2026-09) redesigned the
  FSM set; v1 payloads decode with the state translated (fromV1Id), so both
  recordings on disk keep replaying.
- Layout must be tiling (KD-tree), everything fits the viewport, no page
  scroll, no holes, min sizes respected.
- Dead reckoning is computed **ground-side**, decoupled module (like serial).
  Live-only; the store's 1 Hz extrapolator keeps it advancing through a total
  link loss and `_rebuildState` republishes it (otherwise widgets freeze DR at
  the last fix). `TelemetryStore.drStaleMs` (1000) is the shared stale
  threshold (store, 3D view, position panel). Map draws one dashed segment per
  gap rooted at the last known fix (>3 s DR silence splits); readouts clamp DR
  altitude at the site MSL and the 3D rocket stands on its tail (base lift
  0.62 model units) so nothing sinks through the plane.
- Top bar has a RESET button (confirm dialog) clearing history, DR, max
  values and the battery average — recordings on disk are kept; hidden in replay.
- Workspace grid has outer padding (`AppDimens.outerPadding`) so tiles never
  touch the window edge; all custom buttons use the pointer cursor.
- Charts display raw data — no smoothing/filtering; all share one code path.
- Keep the codebase modular/data-driven; one-file + one-registry-entry to add
  widgets; shared `TimeSeriesChart`.
- **Dark mode** (settings → Appearance, persisted `trycatch.dark_mode.v1`):
  `AppPalette` light/dark + `AppThemeMode` notifier; `AppColors` are getters
  resolving the active palette, so NEVER hold them in a `const` (analyzer
  enforces) — and NEVER `const`-instantiate a widget that (transitively)
  reads them (`const AppShell`/`TopBar`/screens/`Center(WaitingForData)`
  froze whole subtrees across flips). `AppText.microLabel/monoValue` are
  getters for the same reason. Map tiles stay light in both modes.
  (2026-09). Team color is pink `#FF00A1`; design direction "D — Precision
  Light" from the `design_mockups/` HTML mockups (A dark was rejected;
  B2/C2 were the runners-up).
- **Do not start the app yourself** — the user runs it. Do not take
  screenshots; ask the user for screenshots/descriptions instead.
- Debug builds are janky; for smoothness checks suggest `flutter run -d
  windows --release`. Perf fixes so far: zero-copy ring-buffer history views,
  memoized tree layout.

## 9. State / next steps

- Analyzer clean, 111 tests green (`flutter test`) at last full green run.
  NOTE (2026-09-09): suite is currently red — an in-progress serial-package
  `RecordingHeader` refactor (uncommitted) leaves `file_parser.dart`
  referencing a `PacketParser(payloadLength:)` that doesn't exist yet, so
  every test importing `package:serial` fails to compile. Unrelated to the
  3D-widget work; finish the refactor to go green again. Nothing committed
  to git yet
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
