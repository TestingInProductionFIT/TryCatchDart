/// Sync-word scanner for raw recording bytestreams.
///
/// The channel-health tile counts a packet as "ours" only when the active
/// connector's parser finds its sync word at the expected stride. When the
/// chart shows steady red (unknown) spikes with zero green (ours) — as in
/// the Demo-connector report — the fastest proof is to count sync words in
/// the recorded raw bytes.
///
/// Usage:
/// ```sh
/// dart run tool/scan_recording_sync.dart <recording.bin>
/// ```
/// Record 15–20 s on the failing port first (Record button): the recorder
/// saves the verbatim bytestream even when the parser matches nothing, so a
/// zero-sync report points at the link layer (baud / wiring), not the parser.
library;

import 'dart:io';

import 'package:serial/serial.dart';

Future<void> main(List<String> args) async {
  if (args.isEmpty) {
    stderr.writeln('Usage: dart run tool/scan_recording_sync.dart <file.bin>');
    exitCode = 2;
    return;
  }
  final path = args.first;
  final header = await tryReadRecordingHeader(path);
  if (header == null) {
    stderr.writeln('Not a v3 recording (bad magic/CRC): $path');
    exitCode = 1;
    return;
  }
  final chunks = await readRecordingChunks(path);
  stdout.writeln('header connector=${header.connectorId} '
      'packetCount=${header.packetCount} chunks=${chunks.length}');
  if (chunks.isEmpty) {
    stdout.writeln('No telemetry chunks — nothing was received on the port.');
    return;
  }
  // Chunk cadence: a healthy link delivers full packets on the rocket's
  // tick (e.g. demo Realtime every ~400 ms with 33 B). Dribbles of a few
  // bytes on the right cadence with no sync = garbled link (baud/config).
  for (var i = 0; i < chunks.length; i++) {
    final c = chunks[i];
    final dt = i == 0 ? 0 : c.tsUs - chunks[i - 1].tsUs;
    stdout.writeln('chunk[$i] +${dt}us len=${c.payload.length} '
        '${_hex(c.payload, c.payload.length)}');
  }
  final raw = <int>[];
  for (final c in chunks) {
    raw.addAll(c.payload);
  }
  stdout.writeln('raw bytes=${raw.length}');
  stdout.writeln('first 64: ${_hex(raw, 64)}');

  _count(raw, 'A5 5A (segfault LE sync)', 0xA5, 0x5A);
  _count(raw, '5A A5 (reversed)', 0x5A, 0xA5);
  _count(raw, 'AA 55 (mock sync)', 0xAA, 0x55);
  _count(raw, '47 43 (uplink GC)', 0x47, 0x43);

  _stride(raw, 0xA5, 0x5A, 'segfault');
  _stride(raw, 0xAA, 0x55, 'mock');

  for (final connector in allConnectors) {
    final parser = connector.createParser();
    for (final c in chunks) {
      parser.feed(c.payload, timestampMs: c.tsMs);
    }
    stdout.writeln('${connector.id}: matchedPackets=${parser.matchedPackets} '
        'matchedBytes=${parser.matchedBytes} '
        'garbage=${parser.garbageBytes} crcErrors=${parser.crcErrorCount}');
  }
}

String _hex(List<int> bytes, int n) {
  final take = bytes.length < n ? bytes.length : n;
  return [
    for (var i = 0; i < take; i++)
      bytes[i].toRadixString(16).padLeft(2, '0'),
  ].join(' ');
}

void _count(List<int> raw, String label, int b0, int b1) {
  var hits = 0;
  for (var i = 0; i + 1 < raw.length; i++) {
    if (raw[i] == b0 && raw[i + 1] == b1) hits++;
  }
  stdout.writeln('$label hits=$hits');
}

void _stride(List<int> raw, int b0, int b1, String label) {
  final positions = <int>[];
  for (var i = 0; i + 1 < raw.length; i++) {
    if (raw[i] == b0 && raw[i + 1] == b1) positions.add(i);
  }
  if (positions.length < 2) {
    stdout.writeln('$label stride: <2 hits, no stride info');
    return;
  }
  final gaps = <int, int>{};
  for (var i = 1; i < positions.length; i++) {
    final gap = positions[i] - positions[i - 1];
    gaps[gap] = (gaps[gap] ?? 0) + 1;
  }
  final top = gaps.entries.toList()
    ..sort((a, b) => b.value.compareTo(a.value));
  final summary = top
      .take(5)
      .map((e) => '${e.key}B x${e.value}')
      .join(', ');
  stdout.writeln('$label stride top gaps: $summary '
      '(expect 33 for segfault, 54 for mock)');
}
