import 'dart:io';
import 'dart:typed_data';

/// Handles recording raw binary byte streams directly to disk with framing headers.
///
/// Records every raw byte received over the serial interface (including preamble
/// noise, fragmented frames, and corrupted bytes) prepended with a 12-byte framing header
/// (64-bit microsecond timestamp + 32-bit payload length) for complete diagnostic fidelity.
class Recorder {
  IOSink? _sink;
  String? _filePath;
  int _bytesWritten = 0;

  /// Whether a recording session is currently active.
  bool get isRecording => _sink != null;

  /// File path of the active recording session, or `null` if inactive.
  String? get filePath => _filePath;

  /// Total number of raw bytes recorded in the current session.
  int get bytesWritten => _bytesWritten;

  /// Starts a recording session targeting [filePath].
  ///
  /// Automatically creates parent directories if they don't exist and opens
  /// an unbuffered asynchronous write stream.
  Future<void> start(String filePath) async {
    await stop();

    final file = File(filePath);
    await file.parent.create(recursive: true);

    _sink = file.openWrite();
    _filePath = filePath;
    _bytesWritten = 0;
  }

  /// Stops the active recording session, flushes all buffered bytes to disk,
  /// and closes the underlying file handle.
  Future<void> stop() async {
    if (_sink != null) {
      final sink = _sink;
      _sink = null;
      _filePath = null;
      await sink?.flush();
      await sink?.close();
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
  }
}
