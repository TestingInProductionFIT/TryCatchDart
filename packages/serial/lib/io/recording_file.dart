/// Recording file format: fixed header + raw chunk stream.
////
/// Layout (all big-endian, header is 112 bytes):
///
/// | Off | Size | Field         | Type  | Notes                                   |
/// |-----|------|---------------|-------|-----------------------------------------|
/// | 0   | 4    | magic         | u32   | 0x54435243 ('TCRC')                     |
/// | 4   | 2    | version       | u16   | File format version (currently 1)       |
/// | 6   | 2    | headerLength  | u16   | Header size in bytes (112)              |
/// | 8   | 2    | payloadLength | u16   | Wire framing of the body (53/52, else 0)|
/// | 10  | 2    | flags         | u16   | Bit 0: launch site present              |
/// |     |      |               |       | Bit 1: stats present                    |
/// | 12  | 8    | startMicros   | i64   | First chunk timestamp (µs epoch)        |
/// | 20  | 8    | endMicros     | i64   | Last chunk timestamp                    |
/// | 28  | 8    | packetCount   | u64   | Valid decoded packets                   |
/// | 36  | 4    | maxBaroAltM   | f32   | Peak barometric altitude (m AGL)        |
/// | 40  | 4    | maxSpeedMps   | f32   | Peak total speed (m/s)                  |
/// | 44  | 4    | maxAccelMps2  | f32   | Peak total acceleration (m/s²)          |
/// | 48  | 4    | launchLat     | i32   | 1e-7 degrees                          |
/// | 52  | 4    | launchLon     | i32   | 1e-7 degrees                          |
/// | 56  | 4    | launchMslM    | f32   | Site MSL altitude (m)                   |
/// | 60  | 48   | launchName    | u8[48]| UTF-8, NUL-padded, rune-safe truncated |
/// | 108 | 2    | headerCrc     | u16   | CRC16-CCITT over bytes 0..107           |
/// | 110 | 2    | reserved      | u16   | Zero                                      |
///
/// Behind the header the file is the chunk stream: per chunk a 12-byte
/// header (i64 micros + u32 length, big-endian) + raw stream bytes.
/// The header is mandatory — files without the magic are not recordings
/// and every reader below rejects them (use [finalizeRecordingFile] once
/// to upgrade such a body).
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../constants.dart';
import '../telemetry/frame_codec.dart';
import '../worker/protocol.dart';
import 'packet_parser.dart';

/// Magic word opening every v1+ recording file ('TCRC').
const int recordingMagic = 0x54435243;

/// File format version written by this codebase.
const int recordingFormatVersion = 1;

/// Fixed v1 header size in bytes.
const int recordingHeaderLength = 112;

/// Maximum header size ever skipped when probing an unknown file.
const int maxRecordingHeaderLength = 4096;

/// Flag: the launch-site fields carry a real site (or first-fix fallback).
const int recordingFlagLaunchSite = 1 << 0;

/// Flag: the stats fields were computed over the whole body.
const int recordingFlagStats = 1 << 1;

/// Fixed header of a recording file. See the library doc for the layout.
class RecordingHeader {
  /// Wire framing of the body (53 current, 52 legacy, 0 = unknown/probe).
  final int payloadLength;

  final bool hasLaunchSite;
  final bool hasStats;

  /// First chunk timestamp, microseconds since epoch (0 when empty).
  final int startMicros;

  /// Last chunk timestamp, microseconds since epoch.
  final int endMicros;

  final int packetCount;
  final double maxBaroAltM;
  final double maxSpeedMps;
  final double maxAccelMps2;

  final double launchLatitude;
  final double launchLongitude;
  final double launchMslM;
  final String launchName;

  const RecordingHeader({
    this.payloadLength = 0,
    this.hasLaunchSite = false,
    this.hasStats = false,
    this.startMicros = 0,
    this.endMicros = 0,
    this.packetCount = 0,
    this.maxBaroAltM = 0,
    this.maxSpeedMps = 0,
    this.maxAccelMps2 = 0,
    this.launchLatitude = 0,
    this.launchLongitude = 0,
    this.launchMslM = 0,
    this.launchName = '',
  });

  /// Flight duration covered by the body, in milliseconds.
  int get durationMs =>
      endMicros >= startMicros ? (endMicros - startMicros) ~/ 1000 : 0;

  /// Launch site as a [LaunchRef], or `null` when the flag is clear.
  LaunchRef? get launchRef => hasLaunchSite
      ? LaunchRef(
          latitude: launchLatitude,
          longitude: launchLongitude,
          mslM: launchMslM,
          name: launchName,
        )
      : null;

  /// Serializes to exactly [recordingHeaderLength] bytes.
  Uint8List encode() {
    final b = ByteData(recordingHeaderLength);
    b.setUint32(0, recordingMagic, Endian.big);
    b.setUint16(4, recordingFormatVersion, Endian.big);
    b.setUint16(6, recordingHeaderLength, Endian.big);
    b.setUint16(8, payloadLength, Endian.big);
    var flags = 0;
    if (hasLaunchSite) flags |= recordingFlagLaunchSite;
    if (hasStats) flags |= recordingFlagStats;
    b.setUint16(10, flags, Endian.big);
    b.setInt64(12, startMicros, Endian.big);
    b.setInt64(20, endMicros, Endian.big);
    b.setUint64(28, packetCount, Endian.big);
    b.setFloat32(36, maxBaroAltM, Endian.big);
    b.setFloat32(40, maxSpeedMps, Endian.big);
    b.setFloat32(44, maxAccelMps2, Endian.big);
    b.setInt32(48, (launchLatitude.clamp(-90.0, 90.0) / 1e-7).round(),
        Endian.big);
    b.setInt32(52, (launchLongitude.clamp(-180.0, 180.0) / 1e-7).round(),
        Endian.big);
    b.setFloat32(56, launchMslM, Endian.big);
    final nameBytes = _truncateUtf8(launchName, 48);
    b.buffer.asUint8List().setRange(60, 60 + nameBytes.length, nameBytes);
    b.setUint16(108, crc16CCITT(b.buffer.asUint8List(), 0, 108), Endian.big);
    b.setUint16(110, 0, Endian.big);
    return b.buffer.asUint8List();
  }

  /// Parses and validates v1 header bytes (`null` when malformed, a newer
  /// version, or the CRC mismatches).
  static RecordingHeader? decode(Uint8List bytes) {
    if (bytes.length < recordingHeaderLength) return null;
    final b = ByteData.sublistView(bytes, 0, recordingHeaderLength);
    if (b.getUint32(0, Endian.big) != recordingMagic) return null;
    if (b.getUint16(4, Endian.big) != recordingFormatVersion) return null;
    if (b.getUint16(6, Endian.big) != recordingHeaderLength) return null;
    if (b.getUint16(108, Endian.big) != crc16CCITT(bytes, 0, 108)) {
      return null;
    }
    final flags = b.getUint16(10, Endian.big);
    final nameBytes = bytes.sublist(60, 108);
    var nameEnd = nameBytes.indexOf(0);
    if (nameEnd < 0) nameEnd = nameBytes.length;
    return RecordingHeader(
      payloadLength: b.getUint16(8, Endian.big),
      hasLaunchSite: flags & recordingFlagLaunchSite != 0,
      hasStats: flags & recordingFlagStats != 0,
      startMicros: b.getInt64(12, Endian.big),
      endMicros: b.getInt64(20, Endian.big),
      packetCount: b.getUint64(28, Endian.big),
      maxBaroAltM: b.getFloat32(36, Endian.big),
      maxSpeedMps: b.getFloat32(40, Endian.big),
      maxAccelMps2: b.getFloat32(44, Endian.big),
      launchLatitude: b.getInt32(48, Endian.big) * 1e-7,
      launchLongitude: b.getInt32(52, Endian.big) * 1e-7,
      launchMslM: b.getFloat32(56, Endian.big),
      launchName: utf8.decode(nameBytes.sublist(0, nameEnd),
          allowMalformed: true),
    );
  }

  /// Truncates [s] to fit [maxBytes] of UTF-8 without splitting a rune.
  static Uint8List _truncateUtf8(String s, int maxBytes) {
    final out = <int>[];
    for (final rune in s.runes) {
      final encoded = utf8.encode(String.fromCharCode(rune));
      if (out.length + encoded.length > maxBytes) break;
      out.addAll(encoded);
    }
    return Uint8List.fromList(out);
  }
}

/// Body offset of a recording file: the header length when the magic is
/// present with a sane size, else 0 (legacy headerless file).
int recordingBodyOffsetOf(Uint8List prefix, int fileLength) {
  if (prefix.length < 12) return 0;
  final b = ByteData.sublistView(prefix, 0, 12);
  if (b.getUint32(0, Endian.big) != recordingMagic) return 0;
  final headerLength = b.getUint16(6, Endian.big);
  if (headerLength < recordingHeaderLength ||
      headerLength > maxRecordingHeaderLength ||
      headerLength > fileLength) {
    return 0;
  }
  return headerLength;
}

/// Reads and validates the file header of [path], or `null` for legacy,
/// corrupt or newer-version files (which still parse from the body offset).
Future<RecordingHeader?> tryReadRecordingHeader(String path) async {
  try {
    final file = File(path);
    final length = await file.length();
    if (length < recordingHeaderLength) return null;
    final raf = await file.open();
    try {
      final bytes = await raf.read(recordingHeaderLength);
      if (bytes.length < recordingHeaderLength) return null;
      return RecordingHeader.decode(bytes);
    } finally {
      await raf.close();
    }
  } catch (_) {
    return null;
  }
}

/// One raw chunk with its original capture timestamp.
class RecordingChunk {
  /// Capture time, microseconds since epoch (preserved verbatim on write).
  final int tsUs;
  final Uint8List payload;

  const RecordingChunk({required this.tsUs, required this.payload});

  int get tsMs => tsUs ~/ 1000;
}

/// Reads every well-formed chunk of the v1 recording at [path], skipping
/// the file header and stopping at the first corrupt chunk (same tolerance
/// as the parser). Files without the magic yield no chunks.
Future<List<RecordingChunk>> readRecordingChunks(String path) async {
  final file = File(path);
  final raf = await file.open();
  try {
    final length = await raf.length();
    if (length < 12) return const [];
    final prefix = await raf.read(12);
    final pos = recordingBodyOffsetOf(prefix, length);
    if (pos <= 0) return const [];
    await raf.setPosition(pos);
    return await _readChunks(raf, pos, length);
  } finally {
    await raf.close();
  }
}

/// Walks the chunk stream starting at [pos].
Future<List<RecordingChunk>> _readChunks(
    RandomAccessFile raf, int pos, int length) async {
  final out = <RecordingChunk>[];
  var cursor = pos;
  await raf.setPosition(cursor);
  while (cursor + 12 <= length) {
    final header = ByteData.sublistView(await raf.read(12));
    final tsUs = header.getInt64(0, Endian.big);
    final len = header.getUint32(8, Endian.big);
    // Sanity cap (payloads are ~53 bytes) + truncation guard.
    if (len > 4 * 1024 * 1024 || cursor + 12 + len > length) break;
    final payload = Uint8List.fromList(await raf.read(len));
    out.add(RecordingChunk(tsUs: tsUs, payload: payload));
    cursor += 12 + len;
    if (cursor > 512 * 1024 * 1024) break;
  }
  return out;
}

/// Writes [chunks] with their original timestamps (body only, no header —
/// use [writeRecordingFile] for a complete file).
Future<void> writeRecordingChunks(
    String path, List<RecordingChunk> chunks) async {
  final file = File(path);
  await file.parent.create(recursive: true);
  final raf = await file.open(mode: FileMode.write);
  try {
    for (final chunk in chunks) {
      final header = ByteData(12)
        ..setInt64(0, chunk.tsUs, Endian.big)
        ..setUint32(8, chunk.payload.length, Endian.big);
      await raf.writeFrom(header.buffer.asUint8List());
      await raf.writeFrom(chunk.payload);
    }
  } finally {
    await raf.close();
  }
}

/// Writes a complete recording file: [header] followed by [chunks].
Future<void> writeRecordingFile(
  String path,
  RecordingHeader header,
  List<RecordingChunk> chunks,
) async {
  final file = File(path);
  await file.parent.create(recursive: true);
  final raf = await file.open(mode: FileMode.write);
  try {
    await raf.writeFrom(header.encode());
    for (final chunk in chunks) {
      final chunkHeader = ByteData(12)
        ..setInt64(0, chunk.tsUs, Endian.big)
        ..setUint32(8, chunk.payload.length, Endian.big);
      await raf.writeFrom(chunkHeader.buffer.asUint8List());
      await raf.writeFrom(chunk.payload);
    }
  } finally {
    await raf.close();
  }
}

/// Computes the header for the body of [path] (framing probe 53→52) and
/// rewrites the file as header + the original body bytes.
///
/// This is the one place that still reads headerless bodies: it upgrades
/// legacy captures. The body is preserved byte-identically; an existing
/// header is replaced, so the call is idempotent. Failures (empty body,
/// I/O errors) leave the file untouched and yield `null`.
Future<RecordingHeader?> finalizeRecordingFile(
  String path, {
  LaunchRef? launch,
}) async {
  try {
    final file = File(path);
    final length = await file.length();
    if (length < 12) return null;
    final raf = await file.open();
    List<RecordingChunk> chunks;
    List<int> body;
    try {
      final prefix = await raf.read(12);
      // Headered files re-finalize from their body; headerless legacy
      // bodies upgrade from offset 0.
      final offset = recordingBodyOffsetOf(prefix, length);
      chunks = await _readChunks(raf, offset, length);
      if (chunks.isEmpty) return null;
      await raf.setPosition(offset);
      body = await raf.read(length - offset);
    } finally {
      await raf.close();
    }

    var payloadLength = 0;
    var packetCount = 0;
    var maxBaro = 0.0;
    var maxSpeed = 0.0;
    var maxAccel = 0.0;
    LaunchRef? firstFix;
    for (final framing in [TelemetryFraming.payloadLength, 52]) {
      final parser = PacketParser(payloadLength: framing);
      var count = 0;
      var peakBaro = double.negativeInfinity;
      var peakSpeed = 0.0;
      var peakAccel = 0.0;
      LaunchRef? fix;
      for (final chunk in chunks) {
        for (final packet
            in parser.feed(chunk.payload, timestampMs: chunk.tsMs)) {
          final frame = FrameCodec.decode(packet.rawData,
              receivedAtMs: packet.receivedAtMs);
          if (frame == null) continue;
          count++;
          if (frame.baroAltitude > peakBaro) peakBaro = frame.baroAltitude;
          if (frame.speedTotal > peakSpeed) peakSpeed = frame.speedTotal;
          if (frame.accelTotal > peakAccel) peakAccel = frame.accelTotal;
          fix ??= frame.gpsHas3dFix
              ? LaunchRef(
                  latitude: frame.latitude,
                  longitude: frame.longitude,
                  mslM: frame.gpsAltitude,
                )
              : null;
        }
      }
      if (count > 0) {
        payloadLength = framing;
        packetCount = count;
        maxBaro = peakBaro;
        maxSpeed = peakSpeed;
        maxAccel = peakAccel;
        firstFix = fix;
        break;
      }
    }

    final site = launch ?? firstFix;
    final header = RecordingHeader(
      payloadLength: payloadLength,
      hasLaunchSite: site != null,
      hasStats: true,
      startMicros: chunks.first.tsUs,
      endMicros: chunks.last.tsUs,
      packetCount: packetCount,
      maxBaroAltM: maxBaro.isFinite ? maxBaro : 0,
      maxSpeedMps: maxSpeed,
      maxAccelMps2: maxAccel,
      launchLatitude: site?.latitude ?? 0,
      launchLongitude: site?.longitude ?? 0,
      launchMslM: site?.mslM ?? 0,
      launchName: site?.name ?? '',
    );

    final tmp = File('$path.tmp');
    await tmp.writeAsBytes([...header.encode(), ...body], flush: true);
    await tmp.rename(path);
    return header;
  } catch (_) {
    return null;
  }
}
