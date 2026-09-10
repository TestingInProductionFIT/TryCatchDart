import 'package:serial/serial.dart';

/// Raw recording chunk I/O + trimming ("save part of a flight").
///
/// Recording files open with a fixed [RecordingHeader] followed by a flat
/// stream of chunks: a 12-byte header
/// (i64 microseconds big-endian + u32 payload length big-endian) + payload.
/// The recorder stores *raw stream fragments* (whatever bytes arrived in one
/// serial read), NOT one packet per chunk — so chunk payloads must be
/// reassembled with [PacketParser] before [FrameCodec] can decode them.
/// Trimming copies a time slice verbatim, so the result replays like any
/// recording (replay clocks are relative to the first chunk), and writes a
/// fresh header carrying the source's launch site over the kept stats.
///
/// Chunk I/O itself ([RecordingChunk], [readRecordingChunks],
/// [writeRecordingChunks]) lives in the serial package next to the header
/// codec; this file keeps the trim + preview-decode logic.

/// Copies the [startMs]..[endMs] slice (relative to the first chunk) of
/// [srcPath] into [dstPath]. Returns the kept chunk count (0 when empty or
/// the window covers nothing — no file is written then).
///
/// The destination gets a fresh header: stats recomputed over the kept
/// slice, launch site propagated from the source header (required — a
/// siteless source is a legacy file and cannot be trimmed).
Future<int> trimRecording({
  required String srcPath,
  required String dstPath,
  required int startMs,
  required int endMs,
}) async {
  final chunks = await readRecordingChunks(srcPath);
  if (chunks.isEmpty) return 0;
  final t0 = chunks.first.tsMs;
  final kept = [
    for (final c in chunks)
      if (c.tsMs - t0 >= startMs && c.tsMs - t0 <= endMs) c,
  ];
  if (kept.isEmpty) return 0;
  await writeRecordingFile(
    dstPath,
    const RecordingHeader(payloadLength: TelemetryFraming.payloadLength),
    kept,
  );
  final srcHeader = await tryReadRecordingHeader(srcPath);
  final srcLaunch = srcHeader?.launchRef;
  if (srcLaunch == null) {
    throw StateError('Source recording has no launch site.');
  }
  await finalizeRecordingFile(dstPath, launch: srcLaunch);
  return kept.length;
}

/// One decimated position sample for 3D previews: WGS84 + baro altitude.
class TrackPoint {
  final double lat;
  final double lon;
  final double alt;

  const TrackPoint({required this.lat, required this.lon, required this.alt});
}

/// Frames decoded from a recording, oldest first.
class DecodedFlight {
  final List<TelemetryFrame> frames;

  const DecodedFlight(this.frames);

  bool get isEmpty => frames.isEmpty;
}

/// Reassembles the raw stream fragments of a recording into packets and
/// decodes them, oldest first.
///
/// Files without a valid header yield an empty flight — callers keep
/// whatever preview they already have.
Future<DecodedFlight> decodeRecordingFrames(String path) async {
  final framing = (await tryReadRecordingHeader(path))?.payloadLength;
  if (framing != TelemetryFraming.payloadLength) {
    return const DecodedFlight([]);
  }
  final chunks = await readRecordingChunks(path);
  final parser = PacketParser();
  final frames = <TelemetryFrame>[];
  for (final chunk in chunks) {
    for (final packet
        in parser.feed(chunk.payload, timestampMs: chunk.tsMs)) {
      final frame = FrameCodec.decode(packet.rawData,
          receivedAtMs: packet.receivedAtMs);
      if (frame != null) frames.add(frame);
    }
  }
  return frames.isNotEmpty
      ? DecodedFlight(frames)
      : const DecodedFlight([]);
}

/// Decimates baro altitudes for thumbnails/graphs (≤160 points).
List<double> buildAltProfile(List<TelemetryFrame> frames) {
  final alts = [for (final f in frames) f.baroAltitude];
  if (alts.length > 160) {
    final step = alts.length / 160;
    return [for (var i = 0; i < 160; i++) alts[(i * step).floor()]];
  }
  return alts;
}

/// Decimates GPS fixes for 3D previews (≤160 points, oldest first).
List<TrackPoint> buildTrackProfile(List<TelemetryFrame> frames) {
  final fixes = [
    for (final f in frames)
      if (f.gpsHasFix) TrackPoint(lat: f.latitude, lon: f.longitude, alt: f.baroAltitude),
  ];
  if (fixes.length > 160) {
    final step = fixes.length / 160;
    return [for (var i = 0; i < 160; i++) fixes[(i * step).floor()]];
  }
  return fixes;
}
