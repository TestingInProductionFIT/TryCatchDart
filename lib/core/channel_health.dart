import 'package:serial/serial.dart';

import './ring_buffer.dart';

/// One per-sample channel-health point: byte/packet rates over the delta
/// between two consecutive [LinkStats] snapshots.
class ChannelSample {
  final int timestampMs;
  final double matchedBps;
  final double unmatchedBps;
  final double packetRate;

  const ChannelSample({
    required this.timestampMs,
    required this.matchedBps,
    required this.unmatchedBps,
    required this.packetRate,
  });
}

/// Verdict on whether the frequency looks free for our link.
enum ChannelVerdict {
  /// Almost no undecodable traffic — safe to fly.
  clear,

  /// Some stray bytes — keep an eye on it before launch.
  activity,

  /// Sustained undecodable traffic — someone else is on this frequency.
  interference,
}

/// Thresholds (unmatched bytes/s) separating the verdicts. Our own link at
/// 10 Hz × 55 B ≈ 550 B/s matched; anything undecodable above a few hundred
/// B/s sustained is another transmitter, not noise.
abstract final class ChannelThresholds {
  static const double activityBps = 50;
  static const double interferenceBps = 400;
}

ChannelVerdict verdictFor(double unmatchedBps) {
  if (unmatchedBps >= ChannelThresholds.interferenceBps) {
    return ChannelVerdict.interference;
  }
  if (unmatchedBps >= ChannelThresholds.activityBps) {
    return ChannelVerdict.activity;
  }
  return ChannelVerdict.clear;
}

/// Turns cumulative [LinkStats] snapshots into per-second rate samples.
///
/// Feeding is idempotent w.r.t. resets: when the worker reconnects its
/// counters restart at zero, which looks like a backwards snapshot — the
/// tracker then clears its history and re-baselines without emitting a
/// (bogus negative) sample.
class ChannelHealthTracker {
  final RingBuffer<ChannelSample> samples;

  LinkStats? _prev;

  ChannelHealthTracker({int capacity = 240}) : samples = RingBuffer(capacity);

  /// Latest computed rates, or `null` before two snapshots arrive.
  ChannelSample? get latest => samples.isEmpty ? null : samples[0];

  /// Feeds a snapshot; returns the new sample, or `null` when baselining.
  ChannelSample? addSnapshot(LinkStats next) {
    final prev = _prev;
    _prev = next;
    if (prev == null) return null;
    // Worker reset (reconnect): counters restarted — drop history.
    if (next.totalBytes < prev.totalBytes ||
        next.matchedBytes < prev.matchedBytes ||
        next.timestampMs <= prev.timestampMs) {
      samples.clear();
      return null;
    }
    final dtS = (next.timestampMs - prev.timestampMs) / 1000.0;
    if (dtS <= 0) return null;
    final sample = ChannelSample(
      timestampMs: next.timestampMs,
      matchedBps: (next.matchedBytes - prev.matchedBytes) / dtS,
      unmatchedBps: (next.unmatchedBytes - prev.unmatchedBytes) / dtS,
      packetRate:
          (next.matchedPackets - prev.matchedPackets).clamp(0, 1 << 30) / dtS,
    );
    samples.push(sample);
    return sample;
  }

  void reset() {
    samples.clear();
    _prev = null;
  }
}

/// Human rate formatting: 950 → "950 B/s", 2400 → "2.4 kB/s".
String formatBps(double bps) {
  if (bps < 1000) return '${bps.round()} B/s';
  if (bps < 10000) return '${(bps / 1000).toStringAsFixed(1)} kB/s';
  return '${(bps / 1000).round()} kB/s';
}

/// One fixed-width time bin of a recording's channel profile: raw byte
/// counters decoded from the recorded chunk stream (garbage included — the
/// saved chunks are the verbatim radio traffic, same as live).
class ChannelBin {
  /// Start offset from the recording start, in milliseconds.
  final int startMs;

  final int durationMs;
  final int matchedBytes;
  final int unmatchedBytes;
  final int matchedPackets;
  final int crcErrors;

  const ChannelBin({
    required this.startMs,
    required this.durationMs,
    this.matchedBytes = 0,
    this.unmatchedBytes = 0,
    this.matchedPackets = 0,
    this.crcErrors = 0,
  });

  double get _dtS => durationMs / 1000.0;
  double get matchedBps => matchedBytes / _dtS;
  double get unmatchedBps => unmatchedBytes / _dtS;
  double get packetRate => matchedPackets / _dtS;
}

/// Buckets raw recording [chunks] into fixed-width bins by feeding them
/// through a [PacketParser] with the same framing as the live path, so a
/// replay shows the same unmatched-bytes/s picture the live monitor did.
///
/// Gaps with no chunks become zero bins, keeping the time axis continuous.
List<ChannelBin> buildChannelProfile(
  List<RecordingChunk> chunks, {
  int binMs = 500,
}) {
  if (chunks.isEmpty) return const [];
  final t0 = chunks.first.tsMs;
  final parser = PacketParser();
  // Per-bin accumulators, grown on demand.
  final matched = <int>[];
  final unmatched = <int>[];
  final packets = <int>[];
  final crcs = <int>[];
  var prevMatched = 0;
  var prevUnmatched = 0;
  var prevPackets = 0;
  var prevCrcs = 0;
  var maxBin = 0;

  void ensure(int bin) {
    while (matched.length <= bin) {
      matched.add(0);
      unmatched.add(0);
      packets.add(0);
      crcs.add(0);
    }
    if (bin > maxBin) maxBin = bin;
  }

  for (final chunk in chunks) {
    final bin = ((chunk.tsMs - t0) ~/ binMs).clamp(0, 1 << 30);
    ensure(bin);
    parser.feed(chunk.payload, timestampMs: chunk.tsMs);
    matched[bin] += parser.matchedBytes - prevMatched;
    unmatched[bin] += parser.unmatchedBytes - prevUnmatched;
    packets[bin] += parser.matchedPackets - prevPackets;
    crcs[bin] += parser.crcErrorCount - prevCrcs;
    prevMatched = parser.matchedBytes;
    prevUnmatched = parser.unmatchedBytes;
    prevPackets = parser.matchedPackets;
    prevCrcs = parser.crcErrorCount;
  }

  return [
    for (var i = 0; i <= maxBin; i++)
      ChannelBin(
        startMs: i * binMs,
        durationMs: binMs,
        matchedBytes: matched[i],
        unmatchedBytes: unmatched[i],
        matchedPackets: packets[i],
        crcErrors: crcs[i],
      ),
  ];
}
