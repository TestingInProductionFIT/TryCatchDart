# TryCatch — Packet & Storage Specification

> **Companion document** to `design.md`. Defines wire formats, decoding mathematics, `.rktf` binary file specification, SQLite schema, and export format specifications.

---

## 1. Physical Wire Protocol (Serial Stream)

- **Transport**: USB CDC Serial (ESP32 TTGO LoRa32 V1)
- **Baud Rate**: 115200 baud, 8 data bits, 1 stop bit, no parity (8N1)
- **Control Lines**: DTR + RTS asserted on connection
- **Framing**: Continuous byte stream without line endings. Packets are identified by a 2-byte Magic Sync Word `[0xA5, 0x5A]` (0x5AA5 little-endian) at byte offset 0 of each packet frame.

---

## 2. Telemetry Packet Formats

### 2.1 Version 1 (V1) — Active Format (33 Bytes)

Packed struct (`#pragma pack(push, 1)`), little-endian byte order throughout.

| Byte Offset | Length | Type | Name | Description & Raw Range | Conversion Formula | Engineering Unit |
|---|---|---|---|---|---|---|
| `0..1` | 2 | `uint16_t` | `syncWord` | Magic sync word | Must equal `0x5AA5` | — |
| `2..3` | 2 | `uint16_t` | `timestampMs` | Milliseconds since rocket boot | Rolls over every ~65.5 s | ms |
| `4` | 1 | `uint8_t` | `packetId` | Rolling packet sequence ID | Rolls over 0–255 | count |
| `5` | 1 | `uint8_t` | `stateFlags` | Rocket FSM state code | Enum: 0=BeforeLaunch, 1=Armed, 2=Flight, 3=ApogeeReached, 4=ChuteDeployed | enum |
| `6..7` | 2 | `int16_t` | `accelX` | IMU Accelerometer X axis | LSB from MPU6050 (±16g range) | raw / 2048.0 * 9.80665 (or / 16384.0 for g) | m/s² (or g) |
| `8..9` | 2 | `int16_t` | `accelY` | IMU Accelerometer Y axis | LSB from MPU6050 | raw / 2048.0 * 9.80665 | m/s² (or g) |
| `10..11` | 2 | `int16_t` | `accelZ` | IMU Accelerometer Z axis | LSB from MPU6050 | raw / 2048.0 * 9.80665 | m/s² (or g) |
| `12..13` | 2 | `int16_t` | `gyroX` | IMU Gyroscope X axis | LSB from MPU6050 (±2000°/s) | raw / 16.4 | deg/s |
| `14..15` | 2 | `int16_t` | `gyroY` | IMU Gyroscope Y axis | LSB from MPU6050 | raw / 16.4 | deg/s |
| `16..17` | 2 | `int16_t` | `gyroZ` | IMU Gyroscope Z axis | LSB from MPU6050 | raw / 16.4 | deg/s |
| `18..19` | 2 | `int16_t` | `kfAltitudeAgl` | Kalman-filtered altitude AGL | In units of 0.1 m (or integer m) | raw / 10.0 | m |
| `20..21` | 2 | `uint16_t` | `rawPressure` | Barometer raw pressure | Barometric sensor reading | raw / 50.0 (or raw * 2.0 Pa) | hPa (or Pa) |
| `22..23` | 2 | `uint16_t` | `triboVoltage` | Triboelectric probe ADC | 12-bit ADC reading | raw * 0.001 (or raw / 1000.0) | V |
| `24` | 1 | `uint8_t` | `batteryVoltage`| Battery voltage ADC | 8-bit scaled ADC reading | raw * 0.02 (or raw * 20 / 1000.0) | V |
| `25..26` | 2 | `int16_t` | `gpsLatOffset` | Latitude offset from base | Offset in units of 1e-5 degrees | baseLat + (raw * 1e-5) | decimal deg |
| `27..28` | 2 | `int16_t` | `gpsLonOffset` | Longitude offset from base| Offset in units of 1e-5 degrees | baseLon + (raw * 1e-5) | decimal deg |
| `29..30` | 2 | `int16_t` | `kfVerticalVelocity` | Kalman-filtered velocity | Vertical velocity (0.1 m/s) | raw / 10.0 | m/s |
| `31..32` | 2 | `uint16_t` | `ky024Analog` | KY-024 Hall Breakaway Sensor | 12-bit analog reading | raw (0–4095) | ADC counts |

### 2.2 Derived Fields Computed by Codec

The decoder computes these standard derived fields:
1. **Total Acceleration**:
   $$a_{\text{total}} = \sqrt{a_x^2 + a_y^2 + a_z^2}$$
2. **Roll & Pitch Angles** (from accelerometer static tilt):
   $$\text{roll} = \operatorname{atan2}(a_y, a_z) \times \frac{180}{\pi}$$
   $$\text{pitch} = \operatorname{atan2}(-a_x, \sqrt{a_y^2 + a_z^2}) \times \frac{180}{\pi}$$
3. **Gravity Compensated Linear Acceleration**:
   Project gravity vector using roll/pitch and subtract from $a_z$ to yield true climb acceleration.

### 2.3 Future Packet Versions (Evolution Architecture)

When new sensors are added (e.g., GPS quality, temperature, high-G accelerometer, additional thermocouples):
1. **Never mutate V1 codec**. Create `V2PacketCodec` with `version = 2`.
2. Register `V2PacketCodec` with `CodecRegistry.instance.register(V2PacketCodec())`.
3. In recorded `.rktf` files, the 2-byte header `codec_version` field dictates which codec is invoked.
4. The UI displays fields dynamically based on `packet.toFieldMap()` and `codec.fields`.

---

## 3. `.rktf` (Rocket Telemetry Format) File Specification

A `.rktf` file is a self-contained, single-file binary format designed for crash safety, fast random access, and multi-platform portability.

### 3.1 File Layout

```
+-------------------------------------------------------------+
|                     HEADER (64 Bytes)                       |
+-------------------------------------------------------------+
|               PACKET RECORD 0 (Variable / Fixed)            |
+-------------------------------------------------------------+
|               PACKET RECORD 1                               |
+-------------------------------------------------------------+
|                          ...                                |
+-------------------------------------------------------------+
|               PACKET RECORD N - 1                           |
+-------------------------------------------------------------+
|               METADATA JSON CHUNK (Appended on Close)       |
+-------------------------------------------------------------+
```

### 3.2 Header Structure (64 Bytes, Fixed)

| Byte Offset | Size | Type | Field Name | Description |
|---|---|---|---|---|
| `0..3` | 4 | `char[4]` | `magic` | ASCII `"RKTF"` (`0x52, 0x4B, 0x54, 0x46`) |
| `4..5` | 2 | `uint16_le`| `file_version` | RKTF format version (currently `1`) |
| `6..7` | 2 | `uint16_le`| `codec_version`| Packet structure version (e.g. `1` for V1 33-byte packet) |
| `8..9` | 2 | `uint16_le`| `packet_length`| Byte size of raw packet payload (`33` for V1) |
| `10..17`| 8 | `int64_le` | `created_at_utc`| Recording start time (microsecond Unix timestamp) |
| `18..25`| 8 | `double_le`| `base_latitude`| Launch pad base latitude (e.g. `49.7983333333`) |
| `26..33`| 8 | `double_le`| `base_longitude`| Launch pad base longitude (e.g. `16.6866666667`) |
| `34..41`| 8 | `double_le`| `ground_alt_msl`| Launch site elevation MSL in meters (e.g. `403.0`) |
| `42..49`| 8 | `uint64_le`| `metadata_offset`| Byte offset to trailing JSON metadata (0 if not closed cleanly) |
| `50..57`| 8 | `uint64_le`| `packet_count` | Total packets in file (0 if crashed; reader scans records) |
| `58..61`| 4 | `uint32_le`| `header_flags` | Flags: Bit 0 = Cleanly closed, Bit 1 = Contains RSSI |
| `62..63`| 2 | `uint16_le`| `header_crc16` | CRC-16-CCITT over bytes `0..61` |

### 3.3 Packet Record Structure (Framed Records)

Each packet appended during flight has a compact 10-byte record header:

| Offset | Size | Type | Name | Description |
|---|---|---|---|---|
| `0..7` | 8 | `int64_le` | `received_at_us` | Wall-clock reception timestamp (microseconds since Unix epoch) |
| `8` | 1 | `int8` | `rssi_dbm` | Signal RSSI in dBm (e.g. -85), or 0 if unavailable |
| `9` | 1 | `uint8` | `flags` | Bit 0 = Valid CRC, Bits 1..7 reserved |
| `10..N`| `packet_length` | `uint8[]` | `raw_bytes` | Verbatim 33-byte packet data from LoRa serial |
| `N+1..N+2` | 2 | `uint16_le` | `record_crc16` | CRC-16 over record header + `raw_bytes` |

- **Total size per record (V1)**: 10 + 33 + 2 = **45 bytes**.
- **Data rate**: At 25 Hz, 1 hour of flight telemetry = $3600 \times 25 \times 45 = 4.05 \text{ MB}$.

### 3.4 Crash Safety & Recovery Algorithm

Because packets are written sequentially with `FileAccess.flush()` every 25 packets (or 1 second):
1. If the computer abruptly loses power or the process crashes, the file remains valid.
2. When opening an `.rktf` file:
   - Verify `magic == "RKTF"`.
   - If `header_flags & 0x01 == 0` (file was not closed cleanly), the reader starts at offset 64 and reads records sequentially until EOF or the first corrupt CRC.
   - The reader counts valid records and reconstructs the index in memory.

---

## 4. SQLite Database Schema (Index & Metadata Cache)

The SQLite database (`flights.db`) acts as a queryable index to avoid scanning thousands of `.rktf` files on startup.

```sql
-- Table: flights
CREATE TABLE IF NOT EXISTS flights (
    id TEXT PRIMARY KEY NOT NULL,              -- UUID v4
    name TEXT NOT NULL,                        -- e.g. "Czech Rocket Challenge 2026 Flight 1"
    file_path TEXT NOT NULL UNIQUE,            -- Relative or absolute path to .rktf file
    created_at INTEGER NOT NULL,               -- Unix epoch ms
    duration_ms INTEGER,                       -- Total flight duration ms (null if active)
    packet_count INTEGER NOT NULL DEFAULT 0,   -- Total decoded telemetry packets
    codec_version INTEGER NOT NULL DEFAULT 1,  -- Telemetry packet format version
    profile_id TEXT,                           -- Associated Launch Profile ID
    base_latitude REAL NOT NULL,               -- Launch site base latitude
    base_longitude REAL NOT NULL,              -- Launch site base longitude
    max_altitude REAL,                         -- Peak barometric altitude (m)
    max_velocity REAL,                         -- Peak vertical velocity (m/s)
    max_acceleration REAL,                     -- Peak total acceleration (m/s² or g)
    is_complete INTEGER NOT NULL DEFAULT 0     -- 1 = cleanly finalized, 0 = active/crashed
);

-- Table: launch_profiles
CREATE TABLE IF NOT EXISTS launch_profiles (
    id TEXT PRIMARY KEY NOT NULL,              -- UUID v4
    name TEXT NOT NULL,                        -- e.g. "Vyškov Airfield"
    base_latitude REAL NOT NULL,
    base_longitude REAL NOT NULL,
    ground_altitude_msl REAL NOT NULL,
    is_default INTEGER NOT NULL DEFAULT 0,
    created_at INTEGER NOT NULL
);

-- Index for fast lookup by date
CREATE INDEX IF NOT EXISTS idx_flights_created_at ON flights (created_at DESC);
```

---

## 5. Export Specifications

### 5.1 CSV Format (RFC 4180)

Header row with standard telemetry column names:
```csv
received_at_utc,timestamp_ms,packet_id,fsm_state_code,fsm_state_label,accel_x_g,accel_y_g,accel_z_g,accel_total_g,gyro_x_dps,gyro_y_dps,gyro_z_dps,altitude_agl_m,pressure_hpa,tribo_voltage_v,battery_voltage_v,latitude,longitude,vertical_velocity_mps,hall_adc,roll_deg,pitch_deg,rssi_dbm
2026-08-24T13:00:00.040Z,46887,0,1,ARMED,-0.218,-0.229,3.240,3.255,4.45,-19.09,2.44,0.00,968.71,0.028,4.00,49.799453,16.692897,0.20,2154,-3.5,4.2,-78
```

### 5.2 JSON Lines Format (`.jsonl`)

Each line is a single JSON object:
```json
{"receivedAt":"2026-08-24T13:00:00.040Z","codecVersion":1,"packetId":0,"timestampMs":46887,"stateFlags":1,"fsmState":"ARMED","accelX":-0.218,"accelY":-0.229,"accelZ":3.24,"accelTotal":3.255,"gyroX":4.45,"gyroY":-19.09,"gyroZ":2.44,"kfAltitudeAgl":0.0,"rawPressure":968.71,"triboVoltage":0.028,"batteryVoltage":4.0,"gpsLat":49.799453,"gpsLon":16.692897,"kfVerticalVelocity":0.2,"ky024Analog":2154,"roll":-3.5,"pitch":4.2,"rssi":-78}
```
