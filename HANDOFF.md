# TryCatchDart — Project Context & Handoff

> Ground station for model rockets ("Testing in Production"). Flutter desktop
> app (Windows x86_64 + ARM64, Linux, macOS — primary dev target Windows),
> "Precision Light" UI. Compacts all relevant knowledge and decisions.
> Update it when things change.

## 1. Stack & conventions

- Flutter SDK ^3.13, run from `C:\Users\wwwho\flutter`. Desktop shells
  scaffolded for Windows, Linux, macOS.
- **Riverpod 3** (no codegen): `Notifier` / `AsyncNotifier`, `AsyncValue.value`
  (NOT `valueOrNull`), `ProviderScope.overrides` injects the worker in main.
- `fl_chart` 1.2 (`SideTitleWidget(meta: meta, child:)`,
  `LineChart(duration: Duration.zero)`, `StrokePattern.dashed`, `BarAreaData`,
  old API `BorderSide.strokeAlignInside` is a double, not an enum).
- `flutter_map` 8.3 + `latlong2`, `vector_math`
  (`transformed(Vector4)`, `transformed3(Vector3)`, `scaleByDouble(x,y,z,w)`),
  `shared_preferences`, `path_provider`, `window_manager`, `tray_manager`,
  `flutter_libserialport`, local package `packages/serial`.
- No router package (4 flat screens via enum provider). No build_runner/freezed.
- Linux native shell (`linux/runner/my_application.cc`): GtkHeaderBar only
  on GNOME-like desktops (env `*DESKTOP*` has gnome/unity/pantheon/budgie,
  or X11 WM is GNOME Shell/Mutter); KDE Plasma (kde/plasma markers or
  `KDE_SESSION_VERSION`, any backend) and all other WMs fall back to a
  traditional title bar so KWin/the compositor draws native decorations.
  Native title is `TryCatch` (matches `WindowOptions`/tray); X11 window icon
  resolves `linux/assets/icon.png` (dev) then `assets/icon.png` (bundle).
  On Wayland the icon NEVER comes from `gtk_window_set_icon` — it comes from
  the hicolor theme via the .desktop entry, so: full 16–512 px set in
  `packaging/linux/icons/hicolor/*/apps/com.krychlic.trycatch.png` (generated
  from `assets/icon.png`; release workflow copies the whole tree into the
  AppDir), and `StartupWMClass=com.krychlic.trycatch` must equal the Wayland
  app_id or the compositor shows a generic icon. For `flutter run`,
  `tool/install-linux-desktop-entry.sh` installs the entry + icons to
  `~/.local/share`.
- Pointer input, desktop: a precision-touchpad two-finger swipe arrives as
  `PointerPanZoom` events, NOT wheel scrolls. flutter_map ignores those for
  zoom (and its drag recognizers ignore pure swipes too — a swipe did
  nothing on the map), while the framework routes the swipe to drag
  recognizers (a swipe tilted the 3D views via `onPanUpdate`). So every
  map/3D view handles both paths: wheel (`scrollWheelZoom` flag /
  `Listener.onPointerSignal`) plus an explicit `onPointerPanZoomUpdate`
  handler. Map zooms swipes with the wheel velocity, cursor-anchored via
  `focusedZoomCenter`, and skips updates carrying scale (flutter_map's own
  pinch-zoom owns those — handling both would double-zoom). The 3D shell +
  rocket tile zoom from swipe (`scrollZoomFactor`, ×1.1 per 120 units, same
  curve as the wheel) and pinch scale ratio, and suppress drag-orbit while
  a trackpad gesture is active (a real press clears the flag, so a lost
  gesture-end can't wedge orbiting off). Pinned by `scroll_zoom_test.dart`.
- `tray_manager` 0.5.3 still calls the deprecated `app_indicator_new()`
  (upstream has not moved to `ayatana_app_indicator_new`), and our
  `APPLY_STANDARD_SETTINGS` adds `-Werror` — so `linux/CMakeLists.txt` adds
  a targeted `-Wno-deprecated-declarations` to the `tray_manager_plugin`
  target only (guarded by `if(TARGET …)`); our own code keeps `-Werror`.
- Theme (`lib/theme/`): white/dark cards (radius 12/8) on cool grey, hairline
  borders, monospace micro-labels (Consolas via `AppText`), team pink `#FF00A1`
  as the single accent (`pinkDeep` for text-safe accents; status stays
  green/amber/red). `AppCard` header = pink dot + mono uppercase label +
  hairline divider (**no tinted band**). `StatusPill` = mono uppercase stadium.
  Series colors: baro alt = pink, GPS/horiz = blue, DR/battery = violet,
  vert = green, accel = amber. Default font (user declined bundling Inter).
- **Dark-mode const rule**: `AppColors`/`AppText.microLabel/monoValue` are
  getters resolving the active palette — NEVER hold them in a `const`, and
  NEVER `const`-instantiate a widget that (transitively) reads them
  (`const AppShell`/`TopBar`/screens froze whole subtrees across flips).
  Map tiles stay light in both modes.
- **Impeller/Windows-ARM64 blank-paint bug**: per-card `BoxShadow` +
  `Clip.antiAlias` on grid tiles silently blanks the workspace grid (layout
  verified correct, no exceptions). So `AppCard` has **no boxShadow** and uses
  `Clip.hardEdge` — do not reintroduce either on grid tiles without testing
  on-device. Grid keeps dividers as (invisible) `Positioned` children in live
  mode so the Stack child shape is identical in both modes. Fallback:
  `flutter::ImpellerSwitch::Disabled` in `windows/runner/flutter_window.cpp`.
- Analyzer clean; `flutter test` green (144 at last green run).

## 2. Serial package — single wire format, no versioning

Framing: sync `0xAA55` + payload 52 bytes (incl. trailing CRC16).
`telemetry/frame_codec.dart` `TelemetryLayout`, big-endian:

```
0  flags u8 (bit0 gpsFix, bit1 gpsFix3d)
1  seq u16              3  gpsLat i32 1e-7deg     7  gpsLon i32 1e-7deg
11 gpsAlt i32 cm        15 baroAlt i32 cm       19 velN i16 cm/s   21 velE   23 velD
25 accelX/Y/Z i16 mg    31 gyroX/Y/Z i16 centidps (±327 dps)
37 heading u16 centideg 39 roll i16 centideg 41 pitch 43 yaw
45 battery u16 mV       47 hall u16 raw (~2500 intact / ~2950 broken)
49 fsmState u8          50 crc16-ccitt (init 0xFFFF, poly 0x1021)
```

Units: WGS84 deg, metres, NED velocity (Down+), body-frame specific force
(+9.81 at rest), gyro deg/s, rocket-oriented attitude (pitch = tilt from
vertical, yaw = compass heading, roll = spin). `FsmState` ids: idle 0, armed 1,
ascent 2, apogee 3, parachute 4, landed 5, debug-unlocked 6, debug-locked 7,
unknown 255 — with airframe flags (`hasNosecone` on
idle/armed/ascent/debug-locked; `hasParachute` on parachute only) that the 3D
views render from. CRC check vector `"123456789"` → 0x29B1. `PacketParser`
has fixed framing.

Recording files (`io/recording_file.dart`): 108-byte header + chunk stream.
Header (big-endian): magic `TCRC` u32, payloadLength u16 (=52), flags u16
(launch site / stats), start/end micros i64, packetCount u64, max
baro/speed/accel f32, launch lat/lon i32 1e-7deg, launch MSL f32, launch name
48 B UTF-8 NUL-padded, CRC16 over bytes 0..103, reserved. Launch site is
mandatory: `start` requires it (the provisional header already carries it,
so even crash-interrupted files have a site) and `stop` finalizes with it
via `finalizeRecordingFile` (never throws; idempotent). No first-GPS-fix
fallback anywhere — siteless files are legacy and rejected (replay errors,
trim throws).
Readers require a valid header; magic-less files rejected everywhere.
`FlightSimulator` (seeded): coldStart 2 s → pad 6 s (armed after 2 s) →
boost 2.8 s @55 m/s² → coast (drag 4e-4) → apogee ~1058 m + hall break →
drogue (~40 m/s) → main @150 m (~6 m/s) → landed (pitch 85°); GPS random-walk,
eastward wind drift, battery 8.4 V −2.5 mV/s; Prague pad. `MockSerialPort`
runs it at 10 Hz plus a 20 s interference cycle (12 s clean / 4 s light /
4 s heavy + bit-flipped clones) so the channel monitor sweeps all verdicts.
Worker isolate: typed commands (Connect/Disconnect/ListPorts/StartRecording/
StopRecording/SendBytes) and events (Packet/PortList/Status/Error) over
SendPort. Chunks carry a 12-byte header (i64 µs + u32 len).

## 3. App architecture

```
lib/
  main.dart          worker spawn → ProviderScope override → AppShell
  ui/screens/        AppShell, router, TopBar, dashboard (tabs + grid),
                     recordings (+orbit previews), monitor, settings
  ui/components/     BrandMark, SerialControls, PacketRateIndicator,
                     ChannelHealthPill, RecordingControls, PlaybackBar,
                     AppCard, StatusPill, ToolFab, WaitingForData,
                     CenteredValue, CopyButton
   ui/tiles/          15 telemetry tiles (incl. channel health); shared/ = TimeSeriesChart,
                     ChartValueHeader, flight scene/painters/shell,
                     rocket mesh, orbit camera, map/satellite tile I/O
  state/             telemetry_store (THE ingestion point),
                     telemetry_provider (streams + serial config),
                     replay_controller, tile_registry, layout_tree,
                     workspace_models, workspace_controller,
                     launch_site_store, router, orbit camera
  services/          flight_trim, prefs_keys
  core/              pure logic (no Flutter/Riverpod): geo, dead_reckoning,
                     ring_buffer, channel_health, packet_rate_tracker, format
  theme/             app_colors (palette + AppThemeMode + tokens), app_theme
```

`TelemetryStore`: decode, DR estimator, ring buffers (9000 ≈ 15 min @10 Hz),
auto-reset on port change, skips live ingestion while replaying, 80 ms
throttle. `history`/`deadReckoningHistory` are zero-copy live views.
DR is gap filler only: points enter history while GPS is silent ≥1 s (1 Hz);
a 1 Hz timer extrapolates through total link loss (live only).
`drStaleMs` (1000) is the shared stale threshold. Persisted keys
(`services/prefs_keys.dart`, no version suffixes): `trycatch.workspaces`,
`trycatch.launch_sites`, `trycatch.dark_mode`.

## 4. Workspace layout = KD-tree

`SplitNode{id (stable), vertical, ratio, a, b}` | `LeafNode{tileId, tileType}`.
Every tile type has a pixel min size; `layoutTree()` clamps splits to
minimums. Pure ops: `insertLeaf` (splits largest leaf, orientation from
last-known shape), `removeLeaf`, `swapLeaves`, `treeFromOrder` (factory
default), `SplitNode.flipOrientation` (double-click a divider in edit mode).
JSON: `{type:'split',id,vertical,ratio,a,b}` / `{type:'leaf',tileId,tileType}`.
Controller: addTile/removeTile/swapTiles/setRatio/setActive/create/duplicate/
rename/delete/resetToDefaults/persistActive (drags mutate with
`persist:false`, persist on release). Grid memoizes layout by root identity +
size. Edit mode: dividers draggable, drag-to-swap, per-tile split/remove,
tile content in `AbsorbPointer`. Dashboard: tabs (Ctrl+1..9, right-click
menu, tooltips), Edit layout toggle, Add-tile picker (`showTilePicker`,
also used for per-tile split), Reset with confirm. Tile registry is
data-driven — new tile = one class + one descriptor entry (id, title,
description, minSize, immersive, builder).

## 5. Tiles

Shared pieces: `TimeSeriesChart` (below), `ChartValueHeader` (big readout for
battery/hall), `CenteredValue` (centred headline + sublabel; pins a tight
LayoutBuilder box so FittedBox actually shrinks — unbounded Column height
used to defeat scaleDown and stripe tiles), `Flight3dShell` (camera-state
mixin + gesture canvas/tool column/readout), `tile_io.dart` (Esri URLs,
download, image check, shared disk cache), `CopyButton`, format helpers,
`PrefsKeys`. Rocket attitude view reuses `paintRocketMesh`/`paintCompass`.

- **Chart**: raw data, no smoothing; 60 s rolling window (replay: whole
  flight, fixed y bounds, played full opacity + remainder 25%); 1-2-5 y
  steps with zero baseline; flat data opens the axis (was the
  `horizontalInterval = 0` crash); decimation ≤400 pts by absolute packet
  time (no left-edge flicker); legend collapses under ~120 px tile height.
  Thin wrappers: altitude, velocity (horiz/vert-dashed/total), acceleration
  (horiz/total), battery (+discharge rate line, hidden when short), hall
  (no legend, threshold 2700 colors the readout).
- **FSM**: big state + time-in-state (1 s ticker past last frame when silent;
  replay uses playhead), progress bar + pipeline/debug chip grids (debug row,
  then progress bar, shed when short); two-click send mirrors the control
  panel. **Max alt**: peak + NOW. **Parachute**: icon + OPEN/STOWED
  (icon shrinks when short). **Position**: GPS + DR cards (copy buttons hide
  when short; replay shows GPS only; DR clamps at site MSL, STALE past 1 s).
- **Map** (immersive, edge-to-edge): Esri street (bright, no key) /
  satellite (overzoom past 18); flutter_map 1 GB disk cache; precache
  zooms 13–17 ~1 km around saved sites (auto on save + settings button).
  GPS solid blue vs per-gap dashed violet DR rooted at last fix (live only);
  follow/satellite/zoom ToolFabs; legend hides when small; polylines only
  with >1 point.
- **3D** (all immersive): metric scene east/up/south metres, origin = site or
  first fix; GPS trail only, DR as single violet point; drop line; 1-2-5
  ground grid with N/E labels; N/E/U compass (dimmed when pointing away);
  chase/orbit-field/free cameras (shared angles, local zoom/mode, 80° cap);
  wheel zoom, double-tap reset. Satellite drapes Esri imagery as a
  screen-space mesh (one node per ~21 px ray-cast — affine UV can't twist;
  parent-tile fallback; ≥5 km²; failures uncached + 15 s backoff) with
  procedural sky tinted from patch mean color. **Never** a
  `Canvas.transform` perspective drape — silently paints nothing on
  Impeller/OpenGLES. World frame X east / Y up / Z south (right-handed;
  locked by `flight_3d_scene_test.dart`). Airframe from FSM flags
  (cone pops at apogee, canopy under parachute).
- **Control panel**: `RocketCommands` catalog — bytes are MADE-UP and
  **must be aligned with real firmware before flight**. Two-click confirm
  (3 s), sent feedback, disabled disconnected/during replay.
- **Top bar** (fixed skeleton, nothing shifts): brand · link group (port
  dropdown incl. Rescan item + Connect, packet rate, channel pill) · hairline
  · session (Record) · menu. Slots keep constant width in every state
  (channel pill reserves 96 px, shows OFFLINE muted while disconnected).
  Launch-site button (flag + site name, amber SET SITE when unset) opens the
  site dialog: preset list (tap selects), manual name/lat/lon/alt entry
  (Save as preset / Use), and save-current-rocket-position-as-site (needs a
  live GPS fix, precaches tiles). A site is always selected (no Clear;
  deleting the active preset falls through to another or keeps its values);
  Record stays disabled until one is set. Reset lives in the menu
  (destructive item, confirm dialog, disabled without data / during replay).
  Replay replaces live zones with: REPLAY badge + filename + play + time +
  flexible slider + speed popup + Back to live.
- **Channel health**: anything plotted is NOT our rocket. Verdicts on
  unmatched B/s: clear <50, activity <400, else interference. Screen =
  verdict banner (pill + rate + hint) + chart card + 3 key numbers.
  Dashboard tile (`channel_health`, in Flight + Prep defaults) = compact
  verdict row (dot + CLEAR/ACTIVITY/INTERFERENCE + ours/other B/s) + the
  same rolling/replay chart; short tiles shed to a headline number.
  Replay buckets chunks into 500 ms bins at load; verdict follows playhead.
  Top-bar pill mirrors the verdict (pulsing red on interference, tap opens
  the screen).

## 6. Replay & recordings

`replayProvider`: `play(path)` parses (valid header required), stores header
site; file site wins via `effectiveLaunchSiteProvider`. Siteless files are
rejected with an error (launch site is mandatory in the current format).
Whole flight
pre-decoded once for fixed chart axes; 50 ms ticker × speed (MAX = dump);
`seek()` replays 0→target; auto-pauses at end. No DR during replay.
Recordings screen: stat-first scan (108-byte header) + per-card concurrent
preview decode (session cache by path+size+mtime); orbit-preview 3D cards
(offline, sparkline fallback); open-folder; Trim dialog (altitude graph,
fresh header, kept stats + source site). Factory workspaces: Flight view,
Prep, Replay (no control panel). `crc_real_flight.bin` on disk is stale
(pre-dates de-versioning) — re-convert from `flight_data.js` before use.
Windows AXTree quirk: RESET unfocuses first on mass tree churn;
adjacent Tooltips in grids need `Semantics(container:true)`.

## 7. Decisions & prefs

- Wire format is placeholder; CRC keeps it honest. Single format, no
  versioning — when real firmware lands, replace the layout wholesale.
- Tiling only: everything fits the viewport, no page scroll, no holes.
- Charts show raw data, one shared code path. Modular/data-driven tiles.
- Debug builds are janky — evaluate with `flutter run -d <os> --release`.
- Do not start the app yourself; ask the user for screenshots/descriptions.
- Weak points (known, out of scope): `AppThemeMode` singleton outside
  Riverpod; `ref.listen` in `build` (channel tile/pill, packet-rate);
  `ref.read(workspaceProvider).value` staleness in places; `TelemetryStore`
  god-store with bidirectional `ReplayController` coupling (sync `seek()`
  janks large files); global orbit camera; `SerialConfigNotifier` mixes
  UI/IO/FS.

## 8. Session log (2026-09)

- Structure refactor: de-versioned wire (52 B) + header (108 B, provisional
  header at start / finalize at stop); dropped legacy decoders, migrations,
  converter; extracted shared UI; moved to `ui/state/services/core/theme`;
  `widget→tile` rename. Old `.bin`/prefs orphaned (no release existed).
- UI/UX pass: dropped pressure; fixed dark-mode leaks; immersive map/3D;
  responsive shedding + honest min sizes; workflow guidance everywhere.
- Overflow pass: bounded `CenteredValue`; dropped battery/hall pills;
  trimmed channel numbers; topbar regrouped + REPLAY badge/filename/speed
  popup.
- Topbar rethink: rescan folded into port dropdown, Reset moved to menu,
  fixed-width skeleton (channel slot reserves 96 px), replay slider single
  Expanded. Channel screen rewritten in plain language ("not ours" /
  "good to fly" / "change frequency").
- AXTree spam fix: Windows accessibility bridge spammed
  "Failed to update ui::AXTree ... Nodes left pending" because desktop
  semantics are always on and dozens of live Text nodes repaint at
  telemetry rate. Policy now: display-only live readouts carry
  ExcludeSemantics (inside CenteredValue, ChartValueHeader,
  TimeSeriesChart, channel charts, 3D readout, packet-rate + rec-timer +
  playhead clocks, battery discharge line, map legend/attribution);
  interactive controls (buttons, chips, sliders, dropdowns, menus, fields,
  copy) keep full semantics. Zero visual change. If spam persists, prime
  suspects left: replay Slider value semantics at 20 Hz, tooltip nodes in
  10 Hz-rebuilding tiles (FSM chips, ToolFabs, copy buttons).
- AXTree spam investigation (user hypothesis: ListView+Tooltip): confirmed
  upstream mechanism (flutter/flutter#182444 — adjacent bare anchors in one
  scrollable item merge, dropping overlay-portal identifiers; verified fix
  is Semantics(container:true) per anchor). Audited our tree: FSM/control
  grids already container'd; every other list tooltip is button/InkWell-backed
  (own node) or single-per-item. New test walks the real dashboard semantics
  tree and pins one tooltip node per tab. Three speculative container:true
  wrappers added mid-investigation were REVERTED after the test proved the
  tabs never merged. Kept: replay filename badge hoisted behind a
  path-only watch (was a bare tooltip rebuilding at 20 Hz) + ExcludeSemantics
  on display-only live readouts (reduces bridge traffic, zero visual
  change). Test-harness finding: widget tests cannot cover FS-backed screens
  — initState always runs in the fake-async zone (verified zone identity
  differs even inside runAsync), where path_provider + Directory.list stall
  permanently. If spam persists, suspect hover+rebuild overlay dynamics or
  teardown races; check whether Narrator/screen reader is running.
- Launch-site flow redo (saved-only): selection is always one of the saved
  presets — store normalizes on load (stray selections adopted, dupes
  collapsed, null falls through to first), "Use without saving" removed from
  dialog + settings, deleting the last preset clears to the add-a-site empty
  state. Fixed the settings dropdown assertion crash (value not in items)
  with the invariant + a defensive value. Port-switcher overflow was the
  BoxDecoration border insetting the child 2 px (fixed 128+1+32 children in
  a 161 box) — picker segment now flexes; pinned by widget tests in all
  states incl. long names. Channel screen: tooltip "Ns ago" (axis kept),
  top chip uses a 1 px vertical rule + click cursor, TOTAL series dropped
  from UI and backend (`ChannelSample/ChannelBin.totalBps` removed;
  `LinkStats.totalBytes` stays — worker reset detection needs it). Battery /
  altitude charts lost their single-line legends. FSM debug states always
  render (merged into the pipeline grid) with an arithmetic fit check
  replacing the fixed hide thresholds. BrandMark uses `assets/icon.png`
  (the real badge); the wordmark theme freeze   was const-identity wrappers
  in TopBar (`const Padding` around BrandMark/_NavMenu) — de-consted, pinned
  by TopBar + BrandMark theme tests. Max-altitude tile is peak-only.
- Sites dialog redo: saved list (tap selects, per-row edit/remove), Add on
  top (name, then current-position fill or manual coords; rename deletes the
  original first). Sites removed from settings (offline maps + appearance +
  about remain). Tile coverage check: `tileCacheCoverage` probes the exact
  precache URL set per site via `getTile` (the cache backend exposes no
  size/count stats) — settings Offline Maps shows per-site cached/total with
  progress bars plus a Check button next to Preload (button row wraps).
- Mandatory launch site: a site is always selected (settings Clear removed;
  `select()` non-nullable; deleting the active preset falls through). New
  top-bar `LaunchSiteButton` (fixed slot, amber SET SITE when unset) opens a
  dialog with presets, manual entry and save-current-rocket-position
  (live GPS fix + name → preset + tile precache). Record is disabled without
  a site; `startRecording` no-ops. Wire side: `StartRecordingCommand.launch`,
  `Recorder.start` and `finalizeRecordingFile` all require the site;
  provisional header carries it; first-fix fallback deleted; siteless
   recordings rejected at replay and trim. Tests updated (fake files now
   carry a site).
- Linux tray never worked: tray_manager's Linux backend only implements
  destroy/setIcon/setTitle/setContextMenu, but `_setupSystemTray` called
  `setToolTip` first inside one shared try/catch — the
  MissingPluginException aborted setup before setIcon/setContextMenu ran.
  Now every tray call has its own guard, Linux uses `setTitle` instead of
  `setToolTip`, `popUpContextMenu` is skipped on Linux (the AppIndicator
  shows the registered menu itself), and the icon resolves to an absolute
  path (repo `assets/` in dev, `<exe>/data/flutter_assets/assets/` in a
  bundle). Runtime side is fine (plugin .so bundled, ayatana libs present);
  on Plasma the icon appears via the AppIndicator→SNI bridge in the panel
  system tray.
