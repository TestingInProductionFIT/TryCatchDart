/// One-time migration of v2 (`TCR2`, 136-byte header) recordings to the
/// v3 format (`TCR3`, 168-byte header + connector stamp).
///
/// Every pre-connector recording used the single hard-coded wire format,
/// which is now the `mock` connector — so migrated files are stamped with
/// `connectorId == 'mock'` and the telemetry chunk stream + command log
/// are copied byte-identically. All header stats/launch-site fields are
/// preserved.
///
/// Usage:
/// ```sh
/// dart run tool/migrate_recordings_v3.dart [recordings-dir]
/// ```
/// Without an argument the default `Documents/TryCatch/recordings`
/// directory is used. Each migrated file keeps a `<name>.v2.bak` backup
/// (existing backups are left untouched); already-migrated, empty and
/// non-recording files are skipped with a report line.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:serial/serial.dart';

/// Legacy v2 header size in bytes.
const int _v2HeaderLength = 136;

/// Legacy v2 format version.
const int _v2FormatVersion = 2;

Future<void> main(List<String> args) async {
  final dirPath = args.isNotEmpty ? args.first : _defaultRecordingsDir();
  final dir = Directory(dirPath);
  if (!await dir.exists()) {
    stderr.writeln('Recordings directory does not exist: $dirPath');
    exitCode = 2;
    return;
  }

  var migrated = 0;
  var skipped = 0;
  var failed = 0;
  await for (final entity in dir.list()) {
    if (entity is! File || !entity.path.endsWith('.bin')) continue;
    final result = await _migrateFile(entity.path);
    switch (result) {
      case _Outcome.migrated:
        migrated++;
      case _Outcome.skipped:
        skipped++;
      case _Outcome.failed:
        failed++;
    }
  }
  stdout.writeln(
      'Done: $migrated migrated, $skipped skipped, $failed failed ($dirPath).');
  if (failed > 0) exitCode = 1;
}

enum _Outcome { migrated, skipped, failed }

Future<_Outcome> _migrateFile(String path) async {
  final name = path.split(Platform.pathSeparator).last;
  late final Uint8List bytes;
  try {
    bytes = await File(path).readAsBytes();
  } catch (e) {
    stdout.writeln('FAIL  $name: cannot read ($e).');
    return _Outcome.failed;
  }
  if (bytes.length < _v2HeaderLength) {
    stdout.writeln('SKIP  $name: too small to hold a header.');
    return _Outcome.skipped;
  }
  final view = ByteData.sublistView(bytes, 0, _v2HeaderLength);
  final magic = view.getUint32(0, Endian.big);
  if (magic == recordingMagic) {
    stdout.writeln('SKIP  $name: already v3.');
    return _Outcome.skipped;
  }
  if (magic != recordingMagicV2) {
    stdout.writeln('SKIP  $name: not a recording (bad magic).');
    return _Outcome.skipped;
  }
  if (view.getUint16(104, Endian.big) != crc16CCITT(bytes, 0, 104)) {
    stdout.writeln('FAIL  $name: v2 header CRC mismatch.');
    return _Outcome.failed;
  }
  if (view.getUint16(108, Endian.big) != _v2HeaderLength ||
      view.getUint16(110, Endian.big) != _v2FormatVersion) {
    stdout.writeln('FAIL  $name: not a v2 directory.');
    return _Outcome.failed;
  }
  if (view.getUint16(132, Endian.big) != crc16CCITT(bytes, 108, 132)) {
    stdout.writeln('FAIL  $name: v2 directory CRC mismatch.');
    return _Outcome.failed;
  }
  final payloadLength = view.getUint16(4, Endian.big);
  if (payloadLength != TelemetryFraming.payloadLength) {
    stdout.writeln('FAIL  $name: unexpected framing ($payloadLength).');
    return _Outcome.failed;
  }

  final flags = view.getUint16(6, Endian.big);
  final nameBytes = bytes.sublist(56, 104);
  var nameEnd = nameBytes.indexOf(0);
  if (nameEnd < 0) nameEnd = nameBytes.length;
  final header = RecordingHeader(
    payloadLength: payloadLength,
    hasLaunchSite: flags & recordingFlagLaunchSite != 0,
    hasStats: flags & recordingFlagStats != 0,
    startMicros: view.getInt64(8, Endian.big),
    endMicros: view.getInt64(16, Endian.big),
    packetCount: view.getUint64(24, Endian.big),
    maxBaroAltM: view.getFloat32(32, Endian.big),
    maxSpeedMps: view.getFloat32(36, Endian.big),
    maxAccelMps2: view.getFloat32(40, Endian.big),
    launchLatitude: view.getInt32(44, Endian.big) * 1e-7,
    launchLongitude: view.getInt32(48, Endian.big) * 1e-7,
    launchMslM: view.getFloat32(52, Endian.big),
    launchName:
        utf8.decode(nameBytes.sublist(0, nameEnd), allowMalformed: true),
    // Pre-connector files are all the original wire format.
    connectorId: mockConnector.id,
  );

  // The body (telemetry chunk stream + command log) is copied verbatim;
  // only the header is replaced. v2 commandsOffset was absolute from a
  // 136-byte header, so v3 shifts it by +32.
  final body = bytes.sublist(_v2HeaderLength);
  final v2TeleLen = view.getUint64(112, Endian.big);
  final v2CommandsOffset = view.getUint64(120, Endian.big);
  final commandCount = view.getUint32(128, Endian.big);
  final teleLen = v2TeleLen.clamp(0, body.length);
  if (commandCount > 0) {
    if (v2CommandsOffset != _v2HeaderLength + v2TeleLen ||
        teleLen + commandCount * 16 > body.length) {
      stdout.writeln('FAIL  $name: v2 command section is truncated.');
      return _Outcome.failed;
    }
  }
  final directory = header.withDirectory(
    telemetryByteLen: teleLen,
    commandsOffset: recordingHeaderLength + teleLen,
    commandCount: commandCount,
  );
  final tmpPath = '$path.migrated.tmp';
  try {
    final tmp = File(tmpPath);
    final sink = await tmp.open(mode: FileMode.write);
    try {
      await sink.writeFrom(directory.encode());
      await sink.writeFrom(body);
    } finally {
      await sink.close();
    }
    // Sanity-check the converted file before replacing the original.
    final check = await tryReadRecordingHeader(tmpPath);
    if (check == null ||
        check.telemetryByteLen != teleLen ||
        check.commandsOffset != recordingHeaderLength + teleLen ||
        check.commandCount != commandCount ||
        check.packetCount != header.packetCount ||
        check.connectorId != mockConnector.id) {
      stdout.writeln('FAIL  $name: converted file did not validate.');
      try {
        await tmp.delete();
      } catch (_) {}
      return _Outcome.failed;
    }
    final backupPath = '$path.v2.bak';
    if (!await File(backupPath).exists()) {
      await File(path).rename(backupPath);
    }
    await tmp.rename(path);
    stdout.writeln(
        'OK    $name: v2 → v3 (${body.length} telemetry bytes, connector ${mockConnector.id}, launch site ${header.hasLaunchSite ? 'kept' : 'absent'}).');
    return _Outcome.migrated;
  } catch (e) {
    stdout.writeln('FAIL  $name: $e.');
    try {
      await File(tmpPath).delete();
    } catch (_) {}
    return _Outcome.failed;
  }
}

/// Default `Documents/TryCatch/recordings` directory (desktop platforms).
String _defaultRecordingsDir() {
  final home = Platform.environment['USERPROFILE'] ??
      Platform.environment['HOME'] ??
      '.';
  return '$home${Platform.pathSeparator}Documents'
      '${Platform.pathSeparator}TryCatch'
      '${Platform.pathSeparator}recordings';
}
