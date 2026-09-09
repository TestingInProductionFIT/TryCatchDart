import 'dart:io';
import 'dart:typed_data';

import '../worker/protocol.dart';
import 'recording_file.dart';

/// Handles recording raw binary byte streams directly to disk with framing headers.
///
/// Records every raw byte received over the serial interface (including preamble
/// noise, fragmented frames, and corrupted bytes) prepended with a 12-byte framing header
/// (64-bit microsecond timestamp + 32-bit payload length) for complete diagnostic fidelity.
///
/// On [stop] a fixed [RecordingHeader] (launch site, span, packet/peak stats)
/// is prepended, turning the file into a self-describing v1 recording. The
/// finalize pass never throws: on any failure the body is left untouched
/// (headerless bodies are rejected by readers — rerun finalize to upgrade).
class Recorder {
  IOSink? _sink;
  String? _filePath;
  LaunchRef? _launch;
  int _bytesWritten = 0;
  int _chunksWritten = 0;

  /// Whether a recording session is currently active.
  bool get isRecording => _sink != null;

  /// File path of the active recording session, or `null` if inactive.
  String? get filePath => _filePath;

  /// Total number of chunk bytes recorded in the current session
  /// (12-byte framing + payload per chunk — excludes the file header
  /// prepended on stop).
  int get bytesWritten => _bytesWritten;

  /// Starts a recording session targeting [filePath].
  ///
  /// [launch] stamps the selected launch site into the file header written
  /// on [stop] (`null` falls back to the first GPS fix in the stream).
  /// Automatically creates parent directories if they don't exist and opens
  /// an unbuffered asynchronous write stream.
  Future<void> start(String filePath, {LaunchRef? launch}) async {
    await stop();

    final file = File(filePath);
    await file.parent.create(recursive: true);

    _sink = file.openWrite();
    _filePath = filePath;
    _launch = launch;
    _bytesWritten = 0;
    _chunksWritten = 0;
  }

  /// Stops the active recording session, flushes all buffered bytes to disk,
  /// prepends the file header, and closes the underlying file handle.
  Future<void> stop() async {
    if (_sink != null) {
      final sink = _sink;
      final path = _filePath;
      final launch = _launch;
      final chunks = _chunksWritten;
      _sink = null;
      _filePath = null;
      _launch = null;
      _chunksWritten = 0;
      await sink?.flush();
      await sink?.close();
      // Header finalize is best-effort: stats pass + rewrite, falling back
      // to the headerless body (still replayable) on any failure. Empty
      // sessions (no chunks) stay empty files, as before.
      if (path != null && chunks > 0) {
        await finalizeRecordingFile(path, launch: launch);
      }
    }
  }

  /// Appends raw [bytes] to the recording file prepended with a 12-byte timestamp frame header.
  ///
  /// Non-blocking O(1) write operation handled by Dart's asynchronous I/O loop.
  void recordBytes(Uint8List bytes) {
    if (_sink == null || bytes.isEmpty) return;

    final timestampMicros = DateTime.now().microsecondsSinceEpoch;

    // 8 bytes (Int64 timestamp) + 4 bytes (Uint32 length) = 12-byte header
    final header = ByteData(12)
      ..setInt64(0, timestampMicros, Endian.big)
      ..setUint32(8, bytes.length, Endian.big);

    _sink!.add(header.buffer.asUint8List());
    _sink!.add(bytes);
    _bytesWritten += 12 + bytes.length;
    _chunksWritten++;
  }
}
