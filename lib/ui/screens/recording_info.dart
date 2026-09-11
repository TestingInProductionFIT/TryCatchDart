import 'dart:io';

import '../../core/flight_events.dart';
import '../../core/geo.dart';
import '../../services/flight_trim.dart';
import '../../state/launch_site_store.dart';

/// Returns true when [site] already exists in [presets] — either under the
/// same name or within [toleranceM] horizontally of a saved preset (same
/// pad, re-recorded or renamed). Used to hide the per-recording
/// "extract launch position" button when there is nothing new to save.
bool isLaunchSiteSaved(
  List<LaunchSite> presets,
  LaunchSite site, {
  double toleranceM = 50,
}) {
  for (final preset in presets) {
    if (preset.name == site.name) return true;
    if (haversineDistanceM(
          preset.latitude,
          preset.longitude,
          site.latitude,
          site.longitude,
        ) <=
        toleranceM) {
      return true;
    }
  }
  return false;
}

/// Metadata + decoded preview about one `.bin` recording.
class RecordingInfo {
  final String path;
  final int sizeBytes;
  final DateTime modified;
  int? durationMs;
  int? packets;
  double? maxAltM;

  /// Launch pad position stamped into the file header (`null` for legacy
  /// siteless or unreadable files — nothing to extract then).
  LaunchSite? launchSite;

  /// Decimated barometric altitude series (≤160 pts) for thumbnails.
  List<double> altProfile = const [];

  /// Decimated GPS track (≤160 pts, oldest first) for the 3D orbit preview.
  List<TrackPoint> track = const [];

  /// Flight milestones (launch / apogee / …) detected from the preview decode,
  /// in frame order — shown as markers in the trim view.
  List<FlightEvent> events = const [];

  /// Whether the preview decode already ran (successfully or not) — cards
  /// skip re-decoding when the session cache hands them a known file.
  bool previewDone = false;

  RecordingInfo({
    required this.path,
    required this.sizeBytes,
    required this.modified,
    this.durationMs,
    this.packets,
    this.maxAltM,
    this.launchSite,
  });

  String get name => path.split(Platform.pathSeparator).last;

  String get directory => path.substring(0, path.length - name.length);

  Future<void> delete() async {
    final f = File(path);
    if (await f.exists()) await f.delete();
  }
}
