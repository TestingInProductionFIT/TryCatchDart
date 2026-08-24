# TryCatch — UI & Interaction Specification

> **Companion document** to `design.md` and `packet_and_storage_spec.md`. Specifies theme tokens, window layout, tile behavior, live charts, map display, 3D rocket view, and command controls.

---

## 1. Visual Theme & Styling (High-Contrast Outdoor Light Mode)

The UI is engineered for **outdoor field use in direct sunlight / bright daylight**, prioritizing crisp contrast, heavy weight indicators, and deep, saturated telemetry colors against a clean light surface.

### Color Palette (Daylight High-Contrast)

- **Background Base**: `#F6F8FA` (Soft neutral gray-white, prevents screen glare)
- **Card / Tile Surface**: `#FFFFFF` (Crisp white for maximum readability)
- **Border / Divider**: `#D0D7DE` (Definitive contrast boundaries between tiles)
- **Border Focus / Active**: `#0969DA` (2px solid border on active/focused tile)
- **Text Primary**: `#1F2328` (Deep charcoal, near-black for sharp text in sunlight)
- **Text Secondary / Units**: `#57606A` (Medium slate gray, legible at a glance)
- **Text Monospace Numbers**: `#0A0C10` (True black, bold weight for digital instrument readouts)

### Instrument & Telemetry Accents (Saturated, Sunlight-Readable)

- **Accent Primary / Altitude**: `#0969DA` (Deep Royal Blue)
- **Velocity / Climb**: `#8250DF` (Deep Purple)
- **Acceleration / G-Force**: `#CF222E` (Vivid Crimson)
- **Triboelectric Sensor**: `#B08800` (Deep Amber Gold)
- **Status Success (Armed / Connected / Good Battery)**: `#1A7F37` (Dark Forest Green)
- **Status Warning (Low Battery / Dropped Packets)**: `#9A6700` (Dark Amber)
- **Status Danger (Disconnected / Emergency / Parachute Fired)**: `#CF222E` (Crimson Red)
- **Map Trajectory Polyline**: `#6639BA` (Bold 3px outline)

### Typography

- **Digital Readouts / Telemetry Data**: `JetBrains Mono` / `Share Tech Mono` / `Roboto Mono` (SemiBold / Bold). Tabular figures (`tnum`) enabled so numbers do not jitter during live updates.
- **UI Labels & Headers**: `Inter` / `system-ui` (Medium / SemiBold, uppercase tracked for section headers).

---

## 2. Shell Layout (Always Visible Header)

```
+---------------------------------------------------------------------------------------------------------+
| [🚀] TryCatch GS   | Mode: [LIVE] [REPLAY] | Port: [ COM5 (ESP32 TTGO) ▼ ] [ CONNECT ] ● CONNECTED      |
| Site: [ Vyskov 2026 ▼ ] | Pkts: 14,290 (24.8 Hz) | Loss: 0.0% | RSSI: -82 dBm | [ RECORD FLIGHT ] [ ⚙ ] |
+---------------------------------------------------------------------------------------------------------+
|                                                                                                         |
|                                         ACTIVE SCREEN AREA                                              |
|                                                                                                         |
+---------------------------------------------------------------------------------------------------------+
```

### Top Bar Elements (Daylight Surface `#FFFFFF` with `#D0D7DE` bottom border)
1. **App Title & Mode Toggle**: Segmented pill button switching between `Live Dashboard` and `Flight Replay`.
2. **Serial Port Selector**:
   - Auto-refreshes every 2 seconds when disconnected.
   - Highlights auto-detected ESP32 devices with a green chip badge.
   - `Connect` / `Disconnect` toggle with a pulsing emerald status dot.
3. **Link Health Panel**:
   - Real-time packet throughput (Hz) calculated over a 1-second rolling window.
   - Link packet loss % over 4-second intervals.
   - Saturated RSSI signal strength bar.
4. **Recording Controller**:
   - `Record Flight`: 1-click start (prompts for flight name or auto-generates timestamped name).
   - When recording: High-visibility red recording badge `● REC (02:45) [ STOP ]` with 2-click safety confirmation on `STOP`.

---

## 3. Live Dashboard Layout

A responsive 3-column telemetry grid on a `#F6F8FA` background with elevated `#FFFFFF` cards:

```
+---------------------------+------------------------------------+-----------------------------+
|    FLIGHT GAUGES & 3D     |         REAL-TIME CHARTS           |     MAP & EXPERIMENTS       |
+---------------------------+------------------------------------+-----------------------------+
| [ FSM STATE: FLIGHT ]     | [ Altitude Profile (AGL) ]         | [ OpenStreetMap GPS Trail ] |
| Alt: 488.6 m              | 500m |             /\              |  - Launch pad marker        |
| Vel: +62.4 m/s            |   0m |____/-------\__\_____        |  - Dynamic rocket marker    |
| Accel: 14.2 G (Total)     |                                    |  - Auto-center toggle       |
+---------------------------+------------------------------------+-----------------------------+
| [ 3D Rocket Orientation ] | [ Vertical Velocity & G-Force ]    | [ Triboelectric Probe (V) ] |
|   (Interactive roll/pitch | +70m/s |           /\              | 5.0V |        /\            |
|    driven by IMU vector)  | -20m/s |__________/__\_______      | 0.0V |_______/__\__________ |
+---------------------------+------------------------------------+-----------------------------+
| [ Battery & Pressures ]   | [ Hall Breakaway / Extra Sensors ] | [ Rocket Command Console ]  |
| Bat: 3.92 V [====--]      | KY-024 ADC: 2154                   | [ Arm Parachute ]           |
| Baro: 968.7 hPa           | RSSI: -84 dBm                      | [ Lock Servos ]             |
+---------------------------+------------------------------------+-----------------------------+
```

### Tile Specifications

1. **Primary Flight Gauge Tile**:
   - Massive 32pt bold digital altitude readout (`#0A0C10`).
   - Rate-of-climb arrow indicator (Green `▲` for climb, Crimson `▼` for descent).
   - Peak altitude callout badge.
2. **3D Rocket Orientation Widget**:
   - Rendered using Flutter `CustomPainter` with high-contrast shaded geometry.
   - Rocket body: White cylinder with bold magenta/navy fin accents and contrasting outline.
   - Rotates in real-time based on roll and pitch calculated from IMU data.
3. **Rolling Charts (fl_chart in Light Mode)**:
   - White plot area with subtle grid lines (`#EAEEF2`).
   - Saturated 2.5px solid trend lines (`#0969DA` altitude, `#8250DF` velocity, `#CF222E` acceleration, `#B08800` triboelectric).
   - Interactive hover tooltip with dark pill background (`#1F2328`) and white text for maximum readability outdoors.
4. **GPS Map Tile (flutter_map)**:
   - Light OpenStreetMap tiles (standard high-contrast cartography).
   - Polyline trail in bold purple (`#6639BA`, width 3.5).
   - High-visibility launch site pad icon (red target) and rocket current position icon (blue rocket pin).
   - Follow toggle: Keep rocket centered in view.
5. **Command Console Tile**:
   - 2-click safety pattern for mission-critical commands.
   - Click once → turns amber (`ARMED (3s)`). Click again within 3 seconds to transmit.
   - Transmits 4-byte command 3 times over serial for uplink reliability.

---

## 4. Rocket Command Set

| Command Name | Byte Sequence | Purpose | Safety Level |
|---|---|---|---|
| **Deploy Parachute** | `[0x47, 0x43, 0xAA, 0x00]` | Immediate pyrotechnic parachute ejection | Critical (2-click confirm) |
| **Lock Servos** | `[0x47, 0x43, 0x55, 0x00]` | Return servo fins/locks to neutral safe state | Normal |
| **Reset Rocket State** | `[0x47, 0x43, 0x67, 0x67]` | Soft-reboot on-board avionics | Critical (2-click confirm) |
| **Force FSM: Before Launch** | `[0x47, 0x43, 0x01, 0x00]` | Override state machine to pre-launch | Manual Override |
| **Force FSM: Armed** | `[0x47, 0x43, 0x01, 0x01]` | Override state machine to armed | Manual Override |
| **Force FSM: Flight** | `[0x47, 0x43, 0x01, 0x02]` | Override state machine to flight | Manual Override |
| **Force FSM: Apogee** | `[0x47, 0x43, 0x01, 0x03]` | Force apogee detection state | Manual Override |
| **Force FSM: Chute Deployed**| `[0x47, 0x43, 0x01, 0x04]` | Force parachute deployed state | Manual Override |

---

## 5. Flight Replay & Export Screen

```
+---------------------------------------------------------------------------------------------------------+
| Recorded Flights: [ 2026-08-24 Flight 1 (3,660 pkts) ▼ ] | Duration: 02:26 | Max Alt: 488.6m | Apogee: T+11.2s|
+---------------------------------------------------------------------------------------------------------+
| [◄◄] [◄] [ ▶ PLAY ] [►] [►►]  Speed: [ 0.5x ] [ 1.0x ] [ 2.0x ] [ 5.0x ]  Time: 00:45.2 / 02:26.4 (31%) |
|                                                                                                         |
| Timeline: [===========================|======▲=============================|==========================] |
|                                   Range Start (T+10s)               Range End (T+120s)                  |
|                                                                                                         |
| [ EXPORT SELECTION ] Format: [ CSV ▼ ] -> [ Export as File... ] | [ Save Range as New .rktf Flight ]    |
+---------------------------------------------------------------------------------------------------------+
| [ Same modular telemetry tiles and charts as Live Screen, updated synchronously with playback ]        |
+---------------------------------------------------------------------------------------------------------+
```

### Replay Controls & Interaction
- **Scrubber Bar**: Click or drag to seek anywhere in the recording instantly ($O(1)$ file offset seek).
- **Synchronized Playhead**: All telemetry graphs, the 3D rocket view, and the GPS map reflect the exact state of the flight at the playhead position.
- **Range Selection Handles**:
  - Two high-contrast draggable handles on the timeline allow isolating specific flight events.
  - Selected packet range can be exported directly to `.csv`, `.jsonl`, or saved as a clean `.rktf` flight file.

---

## 6. Settings & Launch Profiles Screen

- **Launch Site Profiles**:
  - Add / edit / delete profiles.
  - Fields: Profile Name, Base Latitude, Base Longitude, Ground Elevation MSL (m).
  - Interactive map picker to pinpoint launch location coordinates.
- **Serial & Hardware Defaults**:
  - Preferred COM port, auto-connect toggle, baud rate.
- **Packet Codec Version**:
  - Displays registered codecs and active default codec for live decoding.
