#!/usr/bin/env python3
"""Convert the legacy CRCVisualization flight log to a TryCatchDart recording.

Reads the real flight data from the old web visualizer
(`CRCVisualization/flight_data.js`, 3660 packets @25 Hz, 0..146.36 s) and
writes a `.bin` recording that TryCatchDart can replay via the Recordings
screen (same on-disk format the worker's Recorder produces: per chunk a
12-byte header of int64 big-endian timestamp-micros + uint32 big-endian
length, followed by the raw stream bytes `AA55 + 53-byte payload`).

Payload encoding mirrors `packages/serial/lib/telemetry/frame_codec.dart`
`FrameCodec.encode` exactly (big-endian fixed point + CRC16-CCITT over
bytes 0..50, poly 0x1021, init 0xFFFF). The output opens with the v1
`RecordingHeader` (112 bytes, see `packages/serial/lib/io/recording_file.dart`
for the layout): magic 'TCRC', framing 53, span, packet/peak stats and the
launch site (first GPS fix + ISA MSL from the pad pressure).

Field mapping (old -> new wire format):
  time_s (40 ms spacing) -> chunk timestamp micros (fixed base + offset,
      so replay duration is the real 146.36 s)
  lat / lon (deg)        -> gpsLat / gpsLon (1e-7 deg)
  alt (m AGL, baro)      -> baroAlt AND gpsAlt (old log has no separate GPS
      altitude; both carry the baro profile)
  vel (m/s, vertical, up positive) -> velD = -vel; velN/velE are derived
      from the GPS track (central difference over a +/-1 s window, since
      the old GPS only updates ~1 Hz while telemetry runs at 25 Hz)
  accel_x/y/z (G)        -> accelX/Y/Z (m/s^2, x9.80665; pad mean ~4.6 G is
      kept as-is -- that is what the sensor reported)
  gyro_x/y/z (deg/s)     -> gyroX/Y/Z (clamped to the wire +/-327.67 dps;
      the drogue-opening spin spike ~1893 dps saturates, as it would live)
  bat (V, 1S ~4.0)       -> batteryVoltage as-is (note: the battery widget's
      7.9/7.5 V thresholds assume a 2S pack, so it will read LOW -- faithful,
      not faked)
  state                  -> fsmStateId (wire v2): ARMED->armed(1);
      FLIGHT before apogee->ascent(2); apogee + FLIGHT after apogee
      (cone popped, waiting for chute)->apogee(3);
      CHUTE_DEPLOYED->parachute(4), touchdown (alt<=0.5)->landed(5)
  hall                   -> 2500 intact before chute deploy, 2950 after
      (breakaway-wire break, same convention as the mock simulator)
  heading/yaw            -> course-over-ground when horizontal speed >1.5 m/s,
      else hold last (old log has no compass); pitch/roll 0 in flight,
      pitch 85 when landed (same convention as the simulator)
Dropped (no wire fields): pressure, tribo (the old tribo chart has no
counterpart widget -- battery/hall cover that area), ky, temp, gps_qual,
ts_raw. flags = fix|3d always (old gps_qual never drops).

Usage:
  python tools/convert_crc_flight.py [--out PATH]
Default output: <Documents>/TryCatch/recordings/crc_real_flight.bin
"""

import argparse
import json
import os
import struct
import sys
from datetime import datetime, timezone

# --- wire format constants (must match frame_codec.dart / constants.dart) ---
START_WORD = b"\xaa\x55"
PAYLOAD_LEN = 53
G_TO_MS2 = 9.80665

# --- v1 file header (must match packages/serial/lib/io/recording_file.dart) ---
FILE_MAGIC = 0x54435243
FILE_VERSION = 1
FILE_HEADER_LEN = 112
FLAG_LAUNCH_SITE = 1 << 0
FLAG_STATS = 1 << 1
# Fixed recording epoch so the output is byte-reproducible (file mtime still
# shows the real import date in the Recordings screen).
BASE_MICROS = int(datetime(2024, 6, 15, 12, 0, tzinfo=timezone.utc).timestamp() * 1e6)

SRC_DEFAULT = os.path.join(
    os.path.dirname(os.path.abspath(__file__)),
    "..", "..", "CRCVisualization", "flight_data.js",
)
SRC_DEFAULT = os.path.normpath(SRC_DEFAULT)


def crc16_ccitt(data: bytes) -> int:
    crc = 0xFFFF
    for byte in data:
        crc ^= byte << 8
        for _ in range(8):
            crc = ((crc << 1) ^ 0x1021) & 0xFFFF if crc & 0x8000 else (crc << 1) & 0xFFFF
    return crc


def clamp_i16(v: int) -> int:
    return max(-0x8000, min(0x7FFF, v))


def clamp_u16(v: int) -> int:
    return max(0, min(0xFFFF, v))


def clamp_i32(v: int) -> int:
    return max(-0x80000000, min(0x7FFFFFFF, v))


def encode_payload(f: dict) -> bytes:
    b = bytearray(PAYLOAD_LEN)
    struct.pack_into(">B", b, 0, 2)  # wire version 2
    struct.pack_into(">B", b, 1, f["flags"])
    struct.pack_into(">H", b, 2, clamp_u16(f["seq"]))
    struct.pack_into(">i", b, 4, clamp_i32(round(max(-90.0, min(90.0, f["lat"])) / 1e-7)))
    struct.pack_into(">i", b, 8, clamp_i32(round(max(-180.0, min(180.0, f["lon"])) / 1e-7)))
    struct.pack_into(">i", b, 12, clamp_i32(round(f["gps_alt"] * 100)))
    struct.pack_into(">i", b, 16, clamp_i32(round(f["baro_alt"] * 100)))
    struct.pack_into(">h", b, 20, clamp_i16(round(f["vel_n"] / 0.01)))
    struct.pack_into(">h", b, 22, clamp_i16(round(f["vel_e"] / 0.01)))
    struct.pack_into(">h", b, 24, clamp_i16(round(f["vel_d"] / 0.01)))
    struct.pack_into(">h", b, 26, clamp_i16(round(f["acc_x"] / 0.00980665)))
    struct.pack_into(">h", b, 28, clamp_i16(round(f["acc_y"] / 0.00980665)))
    struct.pack_into(">h", b, 30, clamp_i16(round(f["acc_z"] / 0.00980665)))
    struct.pack_into(">h", b, 32, clamp_i16(round(f["gyro_x"] / 0.01)))
    struct.pack_into(">h", b, 34, clamp_i16(round(f["gyro_y"] / 0.01)))
    struct.pack_into(">h", b, 36, clamp_i16(round(f["gyro_z"] / 0.01)))
    struct.pack_into(">H", b, 38, clamp_u16(round(((f["heading"] % 360) + 360) % 360 / 0.01)))
    struct.pack_into(">h", b, 40, clamp_i16(round(f["roll"] / 0.01)))
    struct.pack_into(">h", b, 42, clamp_i16(round(f["pitch"] / 0.01)))
    struct.pack_into(">h", b, 44, clamp_i16(round(f["yaw"] / 0.01)))
    struct.pack_into(">H", b, 46, clamp_u16(round(f["batt"] * 1000)))
    struct.pack_into(">H", b, 48, clamp_u16(f["hall"]))
    struct.pack_into(">B", b, 50, f["fsm"])
    struct.pack_into(">H", b, 51, crc16_ccitt(bytes(b[:51])))
    return bytes(b)


def load_source(path: str) -> list:
    with open(path, encoding="utf-8") as fh:
        txt = fh.read()
    return json.loads(txt[txt.index("["):txt.rindex("]") + 1])


def gps_velocity(data: list, i: int, window: int = 25) -> tuple:
    """Horizontal velocity from the GPS track (m/s N/E).

    Central difference over +/-`window` samples (~1 s each way); the old GPS
    only updates ~1 Hz against 25 Hz telemetry, so a wide window avoids
    stair-step spikes.
    """
    n = len(data)
    a = max(0, i - window)
    c = min(n - 1, i + window)
    dt = data[c]["time_s"] - data[a]["time_s"]
    if dt <= 0:
        return 0.0, 0.0
    vel_n = (data[c]["lat"] - data[a]["lat"]) * 111139.0 / dt
    vel_e = (data[c]["lon"] - data[a]["lon"]) * 71732.0 / dt
    return vel_n, vel_e


def to_frames(data: list) -> list:
    apogee_idx = max(range(len(data)), key=lambda i: data[i]["alt"])
    frames = []
    heading = 0.0
    for pos, d in enumerate(data):
        idx = d["idx"]
        state = d["state"]
        alt = d["alt"]
        vel_n, vel_e = gps_velocity(data, pos)
        horiz = (vel_n ** 2 + vel_e ** 2) ** 0.5
        if horiz > 1.5:
            import math
            heading = (math.degrees(math.atan2(vel_e, vel_n)) + 360) % 360
        if state == "ARMED":
            fsm = 1
        elif state == "FLIGHT":
            # Pre-apogee ascent; at/after apogee the cone is gone and the
            # rocket waits for the chute (APOGEE definition).
            fsm = 2 if idx < apogee_idx else 3
        else:  # CHUTE_DEPLOYED
            if alt <= 0.5 and idx > 1000:
                fsm = 5
            else:
                fsm = 4
        frames.append({
            "seq": idx % 65536,
            "flags": 0x03,
            "lat": d["lat"],
            "lon": d["lon"],
            "gps_alt": alt,
            "baro_alt": alt,
            "vel_n": max(-327.67, min(327.67, vel_n)),
            "vel_e": max(-327.67, min(327.67, vel_e)),
            "vel_d": -d["vel"],
            "acc_x": d["accel_x"] * G_TO_MS2,
            "acc_y": d["accel_y"] * G_TO_MS2,
            "acc_z": d["accel_z"] * G_TO_MS2,
            "gyro_x": d["gyro_x"],
            "gyro_y": d["gyro_y"],
            "gyro_z": d["gyro_z"],
            "heading": heading,
            "roll": 0.0,
            "pitch": 85.0 if fsm == 7 else 0.0,
            "yaw": heading,
            "batt": d["bat"],
            "hall": 2950 if idx >= 290 else 2500,
            "fsm": fsm,
            "time_s": d["time_s"],
        })
    return frames


def write_recording(frames: list, out_path: str, data: list) -> None:
    os.makedirs(os.path.dirname(out_path), exist_ok=True)
    chunks = []
    for f in frames:
        payload = encode_payload(f)
        chunk = START_WORD + payload
        micros = BASE_MICROS + round(f["time_s"] * 1_000_000)
        chunks.append((micros, chunk))
    header = encode_file_header(frames, chunks, data)
    with open(out_path, "wb") as fh:
        fh.write(header)
        for micros, chunk in chunks:
            fh.write(struct.pack(">qI", micros, len(chunk)))
            fh.write(chunk)


def _truncate_utf8(s: str, max_bytes: int) -> bytes:
    out = bytearray()
    for ch in s:
        enc = ch.encode("utf-8")
        if len(out) + len(enc) > max_bytes:
            break
        out += enc
    return bytes(out)


def encode_file_header(frames: list, chunks: list, data: list) -> bytes:
    """v1 RecordingHeader mirroring recording_file.dart (112 bytes)."""
    import math
    max_baro = max(f["baro_alt"] for f in frames)
    max_speed = max(
        math.sqrt(f["vel_n"] ** 2 + f["vel_e"] ** 2 + f["vel_d"] ** 2)
        for f in frames
    )
    max_accel = max(
        math.sqrt(f["acc_x"] ** 2 + f["acc_y"] ** 2 + f["acc_z"] ** 2)
        for f in frames
    )
    # Launch site: first GPS fix; MSL from ISA inversion of the pad pressure
    # (pad 96870.9 Pa -> ~378.4 m, recovering the logger's own model).
    pad_pa = data[0]["pressure"]
    site_msl = 288.15 / 0.0065 * (1 - (pad_pa / 101325.0) ** (1 / 5.25588))
    name = _truncate_utf8("CRCVisualization import", 48).ljust(48, b"\x00")
    head = struct.pack(
        ">IHH HH qq Q fff ii f",
        FILE_MAGIC,
        FILE_VERSION,
        FILE_HEADER_LEN,
        PAYLOAD_LEN,
        FLAG_LAUNCH_SITE | FLAG_STATS,
        chunks[0][0],
        chunks[-1][0],
        len(frames),
        max_baro,
        max_speed,
        max_accel,
        round(data[0]["lat"] / 1e-7),
        round(data[0]["lon"] / 1e-7),
        site_msl,
    )
    head += name
    head += struct.pack(">H", crc16_ccitt(head))
    head += struct.pack(">H", 0)
    assert len(head) == FILE_HEADER_LEN, len(head)
    return head


def verify(out_path: str, frames: list) -> None:
    """Independent read-back: header, framing, CRCs and spot values."""
    with open(out_path, "rb") as fh:
        blob = fh.read()
    (magic, version, header_len) = struct.unpack_from(">IHH", blob, 0)
    assert magic == FILE_MAGIC, hex(magic)
    assert version == FILE_VERSION, version
    assert header_len == FILE_HEADER_LEN, header_len
    (stored_crc,) = struct.unpack_from(">H", blob, 108)
    assert stored_crc == crc16_ccitt(blob[:108]), "file header CRC mismatch"
    (flags, start_us, end_us, count) = struct.unpack_from(">HqqQ", blob, 10)
    assert flags == FLAG_LAUNCH_SITE | FLAG_STATS, flags
    assert count == len(frames), (count, len(frames))
    (max_baro,) = struct.unpack_from(">f", blob, 36)
    assert abs(max_baro - 488.6) < 0.05, max_baro
    print(
        f"header ok: {count} packets, "
        f"{(end_us - start_us) / 1e6:.2f} s, max alt {max_baro:.1f} m"
    )
    off = header_len
    count = 0
    first_ms = last_ms = None
    max_alt = float("-inf")
    while off < len(blob):
        micros, length = struct.unpack_from(">qI", blob, off)
        off += 12
        chunk = blob[off:off + length]
        off += length
        assert chunk[:2] == START_WORD, f"bad sync @packet {count}"
        payload = chunk[2:]
        assert len(payload) == PAYLOAD_LEN, f"bad payload len @packet {count}"
        (stored,) = struct.unpack_from(">H", payload, 51)
        assert stored == crc16_ccitt(payload[:51]), f"CRC mismatch @packet {count}"
        (baro_cm,) = struct.unpack_from(">i", payload, 16)
        max_alt = max(max_alt, baro_cm / 100)
        ms = micros // 1000
        first_ms = ms if first_ms is None else first_ms
        last_ms = ms
        count += 1
    assert count == len(frames), f"packet count {count} != {len(frames)}"
    dur_s = (last_ms - first_ms) / 1000
    print(f"verified {count} packets, CRC ok, duration {dur_s:.2f} s, max alt {max_alt:.1f} m")
    # Spot-check first / apogee / last frames against the source mapping.
    with open(out_path, "rb") as fh:
        raw = fh.read()
    def payload_at(k: int) -> bytes:
        o = header_len
        for _ in range(k + 1):
            _, ln = struct.unpack_from(">qI", raw, o)
            o += 12
            p = raw[o + 2:o + ln]
            o += ln
        return p
    for k in (0, 273, len(frames) - 1):
        p = payload_at(k)
        f = frames[k]
        (lat,) = struct.unpack_from(">i", p, 4)
        (lon,) = struct.unpack_from(">i", p, 8)
        (baro,) = struct.unpack_from(">i", p, 16)
        assert abs(lat * 1e-7 - f["lat"]) < 6e-8, k
        assert abs(lon * 1e-7 - f["lon"]) < 6e-8, k
        assert abs(baro / 100 - f["baro_alt"]) < 0.005, k
        assert p[50] == f["fsm"], (k, p[50], f["fsm"])
    print(f"spot-check ok (packets 0, 273/apogee, {len(frames) - 1})")


def default_out() -> str:
    docs = os.path.join(os.path.expanduser("~"), "Documents")
    return os.path.join(docs, "TryCatch", "recordings", "crc_real_flight.bin")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--src", default=SRC_DEFAULT)
    ap.add_argument("--out", default=default_out())
    args = ap.parse_args()
    data = load_source(args.src)
    print(f"loaded {len(data)} samples from {args.src}")
    frames = to_frames(data)
    from collections import Counter
    print("states:", dict(sorted(Counter(f["fsm"] for f in frames).items())))
    write_recording(frames, args.out, data)
    size = os.path.getsize(args.out)
    print(f"wrote {args.out} ({size / 1024:.0f} KB)")
    verify(args.out, frames)
    return 0


if __name__ == "__main__":
    sys.exit(main())
