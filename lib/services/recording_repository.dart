import 'package:serial/serial.dart';

import '../core/channel_health.dart';
import './flight_trim.dart';

/// Single owner of recording file I/O + decode (layer 3 service).
///
/// State (`ReplayController`) and UI (`recording_card`, `trim_dialog`,
/// `lab_tab`, `recordings_screen`) must go through here instead of calling
/// `FileParser` / `readRecordingChunks` / `FrameCodec` directly, so chunk
/// framing, header validation and decode stay in one place.
abstract final class RecordingRepository {
  /// Loads a recording in a single pass: header + chunks are read once,
  /// then packets/frames/profile are derived in memory.
  static Future<LoadedRecording?> loadReplay(String path) async {
    final header = await tryReadRecordingHeader(path);
    if (header == null ||
        header.payloadLength != TelemetryFraming.payloadLength) {
      return null;
    }
    final launch = header.launchRef;
    if (launch == null) return null;
    final chunks = await readRecordingChunks(path);
    if (chunks.isEmpty) return null;

    final parser = PacketParser();
    final packets = <TelemetryPacket>[];
    final frames = <TelemetryFrame>[];
    for (final chunk in chunks) {
      for (final packet in parser.feed(chunk.payload, timestampMs: chunk.tsMs)) {
        packets.add(packet);
        final frame = FrameCodec.decode(
          packet.rawData,
          receivedAtMs: packet.receivedAtMs,
        );
        if (frame != null) frames.add(frame);
      }
    }
    if (packets.isEmpty) return null;
    return LoadedRecording(
      header: header,
      packets: packets,
      frames: frames,
      channelProfile: buildChannelProfile(chunks),
    );
  }

  /// Preview decode for cards/dialogs/lab (reuses `flight_trim` logic).
  static Future<DecodedFlight> decodePreview(String path) =>
      decodeRecordingFrames(path);
}

/// Fully decoded recording for replay (packets drive the ticker, frames fix
/// chart axes, profile drives the channel-health view).
class LoadedRecording {
  final RecordingHeader header;
  final List<TelemetryPacket> packets;
  final List<TelemetryFrame> frames;
  final List<ChannelBin> channelProfile;

  const LoadedRecording({
    required this.header,
    required this.packets,
    required this.frames,
    required this.channelProfile,
  });
}
