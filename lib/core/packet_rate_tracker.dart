import './format.dart';
import './ring_buffer.dart';

/// Internal sample data structure for packet rate tracking.
class _Sample {
  final int timeMs;
  final int count;

  const _Sample(this.timeMs, this.count);
}

/// Lightweight sliding-window packet rate and timeout calculator.
///
/// Decoupled from UI sampling frequency — snapshots are timestamped
/// and pruned dynamically based on [windowDuration].
class PacketRateTracker {
  final Duration windowDuration;
  final RingBuffer<_Sample> _samples;

  int _totalPackets = 0;
  int? _lastPacketTimeMs;

  PacketRateTracker({
    this.windowDuration = const Duration(seconds: 2),
    int sampleCapacity = 50,
  }) : _samples = RingBuffer<_Sample>(sampleCapacity);

  /// Ingestion: fast integer increments called on incoming packets.
  void recordPacket([int? timestampMs]) {
    _totalPackets++;
    _lastPacketTimeMs = timestampMs ?? DateTime.now().millisecondsSinceEpoch;
  }

  /// Sampling: records odometer snapshot on UI timer ticks.
  void sample([int? currentTimestampMs]) {
    final now = currentTimestampMs ?? DateTime.now().millisecondsSinceEpoch;
    _samples.push(_Sample(now, _totalPackets));
  }

  /// Elapsed time since the most recent packet was received.
  Duration? timeSinceLastPacket([int? currentTimestampMs]) {
    if (_lastPacketTimeMs == null) return null;
    final now = currentTimestampMs ?? DateTime.now().millisecondsSinceEpoch;
    return Duration(milliseconds: (now - _lastPacketTimeMs!).clamp(0, 1 << 30));
  }

  /// Returns true if no packet arrived within [windowDuration].
  bool isTimedOut([int? currentTimestampMs]) {
    final elapsed = timeSinceLastPacket(currentTimestampMs);
    if (elapsed == null) return true;
    return elapsed >= windowDuration;
  }

  /// Moving average rate (packets/sec) over the sliding window.
  double getAveragePacketsPerSecond([int? currentTimestampMs]) {
    if (_samples.length < 2) return 0.0;

    final now = currentTimestampMs ?? _samples[0].timeMs;
    final cutoff = now - windowDuration.inMilliseconds;

    // Find the boundary sample at or just before the cutoff
    _Sample oldest = _samples[_samples.length - 1];
    for (var i = 0; i < _samples.length; i++) {
      if (_samples[i].timeMs <= cutoff) {
        oldest = _samples[i];
        break;
      }
    }

    final deltaCount = _samples[0].count - oldest.count;
    final deltaTimeMs = _samples[0].timeMs - oldest.timeMs;

    if (deltaTimeMs <= 0) return 0.0;
    return (deltaCount * 1000.0) / deltaTimeMs;
  }

  void reset() {
    _totalPackets = 0;
    _lastPacketTimeMs = null;
    _samples.clear();
  }
}

/// Top-bar style label for [rate]: live `X.X pkt/s` while packets arrive
/// within the liveness window, otherwise the age of the last packet
/// (`N.N s ago`) — or `no data` before the first packet ever arrives.
///
/// Pure in ([rate], [nowMs]): pass an explicit clock in tests, wall clock
/// in widgets.
String linkRateLabel(PacketRateTracker rate, [int? nowMs]) {
  if (!rate.isTimedOut(nowMs)) {
    return '${rate.getAveragePacketsPerSecond(nowMs).toStringAsFixed(1)} pkt/s';
  }
  final since = rate.timeSinceLastPacket(nowMs);
  if (since == null) return 'no data';
  return formatPacketAge(since);
}
