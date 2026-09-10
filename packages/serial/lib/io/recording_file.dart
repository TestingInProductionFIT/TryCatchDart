/// Recording file format: fixed header + raw chunk stream.
////
/// Layout (all big-endian, header is 108 bytes, single format — no versioning):
///
/// | Off | Size | Field         | Type  | Notes                                   |
/// |-----|------|---------------|-------|-----------------------------------------|
/// | 0   | 4    | magic         | u32   | 0x54435243 ('TCRC')                     |
/// | 4   | 2    | payloadLength | u16   | Wire framing of the body (52)           |
/// | 6   | 2    | flags         | u16   | Bit 0: launch site present              |
/// |     |      |               |       | Bit 1: stats present                    |
/// | 8   | 8    | startMicros   | i64   | First chunk timestamp (µs epoch)        |
/// | 16  | 8    | endMicros     | i64   | Last chunk timestamp                    |
/// | 24  | 8    | packetCount   | u64   | Valid decoded packets                   |
/// | 32  | 4    | maxBaroAltM   | f32   | Peak barometric altitude (m AGL)        |
/// | 36  | 4    | maxSpeedMps   | f32   | Peak total speed (m/s)                  |
/// | 40  | 4    | maxAccelMps2  | f32   | Peak total acceleration (m/s²)          |
/// | 44  | 4    | launchLat     | i32   | 1e-7 degrees                          |
/// | 48  | 4    | launchLon     | i32   | 1e-7 degrees                          |
/// | 52  | 4    | launchMslM    | f32   | Site MSL altitude (m)                   |
/// | 56  | 48   | launchName    | u8[48]| UTF-8, NUL-padded, rune-safe truncated |
/// | 104 | 2    | headerCrc     | u16   | CRC16-CCITT over bytes 0..103           |
/// | 106 | 2    | reserved      | u16   | Zero                                      |
///
/// Behind the header the file is the chunk stream: per chunk a 12-byte
/// header (i64 micros + u32 length, big-endian) + raw stream bytes.
/// The header is mandatory — files without the magic are rejected by
/// every reader below.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../constants.dart';
import '../telemetry/frame_codec.dart';
import '../worker/protocol.dart';
import 'packet_parser.dart';

/// Magic word opening every recording file ('TCRC').
const int recordingMagic = 0x54435243;

/// Fixed header size in bytes.
const int recordingHeaderLength = 108;

/// Flag: the launch-site fields carry the launch site (always set — a site
/// is required before recording).
const int recordingFlagLaunchSite = 1 << 0;

/// Flag: the stats fields were computed over the whole body.
const int recordingFlagStats = 1 << 1;

/// Fixed header of a recording file. See the library doc for the layout.
class RecordingHeader {
  /// Wire framing of the body (always [TelemetryFraming.payloadLength]).
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
    b.setUint16(4, payloadLength, Endian.big);
    var flags = 0;
    if (hasLaunchSite) flags |= recordingFlagLaunchSite;
    if (hasStats) flags |= recordingFlagStats;
    b.setUint16(6, flags, Endian.big);
    b.setInt64(8, startMicros, Endian.big);
    b.setInt64(16, endMicros, Endian.big);
    b.setUint64(24, packetCount, Endian.big);
    b.setFloat32(32, maxBaroAltM, Endian.big);
    b.setFloat32(36, maxSpeedMps, Endian.big);
    b.setFloat32(40, maxAccelMps2, Endian.big);
    b.setInt32(44, (launchLatitude.clamp(-90.0, 90.0) / 1e-7).round(),
        Endian.big);
    b.setInt32(48, (launchLongitude.clamp(-180.0, 180.0) / 1e-7).round(),
        Endian.big);
    b.setFloat32(52, launchMslM, Endian.big);
    final nameBytes = _truncateUtf8(launchName, 48);
    b.buffer.asUint8List().setRange(56, 56 + nameBytes.length, nameBytes);
    b.setUint16(104, crc16CCITT(b.buffer.asUint8List(), 0, 104), Endian.big);
    b.setUint16(106, 0, Endian.big);
    return b.buffer.asUint8List();
  }

  /// Parses and validates header bytes (`null` when malformed or the CRC
  /// mismatches).
  static RecordingHeader? decode(Uint8List bytes) {
    if (bytes.length < recordingHeaderLength) return null;
    final b = ByteData.sublistView(bytes, 0, recordingHeaderLength);
    if (b.getUint32(0, Endian.big) != recordingMagic) return null;
    if (b.getUint16(104, Endian.big) != crc16CCITT(bytes, 0, 104)) {
      return null;
    }
    final flags = b.getUint16(6, Endian.big);
    final nameBytes = bytes.sublist(56, 104);
    var nameEnd = nameBytes.indexOf(0);
    if (nameEnd < 0) nameEnd = nameBytes.length;
    return RecordingHeader(
      payloadLength: b.getUint16(4, Endian.big),
      hasLaunchSite: flags & recordingFlagLaunchSite != 0,
      hasStats: flags & recordingFlagStats != 0,
      startMicros: b.getInt64(8, Endian.big),
      endMicros: b.getInt64(16, Endian.big),
      packetCount: b.getUint64(24, Endian.big),
      maxBaroAltM: b.getFloat32(32, Endian.big),
      maxSpeedMps: b.getFloat32(36, Endian.big),
      maxAccelMps2: b.getFloat32(40, Endian.big),
      launchLatitude: b.getInt32(44, Endian.big) * 1e-7,
      launchLongitude: b.getInt32(48, Endian.big) * 1e-7,
      launchMslM: b.getFloat32(52, Endian.big),
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

/// Body offset of a recording file: the fixed header length when the magic
/// is present, else 0 (not a recording — rejected by every reader).
int recordingBodyOffsetOf(Uint8List prefix, int fileLength) {
  if (prefix.length < 12) return 0;
  final b = ByteData.sublistView(prefix, 0, 12);
  if (b.getUint32(0, Endian.big) != recordingMagic) return 0;
  if (recordingHeaderLength > fileLength) return 0;
  return recordingHeaderLength;
}

/// Reads and validates the file header of [path], or `null` for corrupt
/// or non-recording files.
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

/// Reads every well-formed chunk of the recording at [path], skipping
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
    // Sanity cap (payloads are ~52 bytes) + truncation guard.
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

/// Computes the header for the body of [path] and rewrites the file as
/// header + the original body bytes.
///
/// An existing header is replaced, so the call is idempotent. Failures
/// (empty body, I/O errors) leave the file untouched and yield `null`.
Future<RecordingHeader?> finalizeRecordingFile(
  String path, {
  required LaunchRef launch,
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
      // Headered files re-finalize from their body; anything else is not
      // a recording and yields null below.
      final offset = recordingBodyOffsetOf(prefix, length);
      if (offset <= 0) return null;
      chunks = await _readChunks(raf, offset, length);
      if (chunks.isEmpty) return null;
      await raf.setPosition(offset);
      body = await raf.read(length - offset);
    } finally {
      await raf.close();
    }

    final parser = PacketParser();
    var packetCount = 0;
    var maxBaro = double.negativeInfinity;
    var maxSpeed = 0.0;
    var maxAccel = 0.0;
    for (final chunk in chunks) {
      for (final packet
          in parser.feed(chunk.payload, timestampMs: chunk.tsMs)) {
        final frame = FrameCodec.decode(packet.rawData,
            receivedAtMs: packet.receivedAtMs);
        if (frame == null) continue;
        packetCount++;
        if (frame.baroAltitude > maxBaro) maxBaro = frame.baroAltitude;
        if (frame.speedTotal > maxSpeed) maxSpeed = frame.speedTotal;
        if (frame.accelTotal > maxAccel) maxAccel = frame.accelTotal;
      }
    }
    if (packetCount == 0) return null;

    final header = RecordingHeader(
      payloadLength: TelemetryFraming.payloadLength,
      hasLaunchSite: true,
      hasStats: true,
      startMicros: chunks.first.tsUs,
      endMicros: chunks.last.tsUs,
      packetCount: packetCount,
      maxBaroAltM: maxBaro.isFinite ? maxBaro : 0,
      maxSpeedMps: maxSpeed,
      maxAccelMps2: maxAccel,
      launchLatitude: launch.latitude,
      launchLongitude: launch.longitude,
      launchMslM: launch.mslM,
      launchName: launch.name,
    );

    final tmp = File('$path.tmp');
    await tmp.writeAsBytes([...header.encode(), ...body], flush: true);
    await tmp.rename(path);
    return header;
  } catch (_) {
    return null;
  }
}
