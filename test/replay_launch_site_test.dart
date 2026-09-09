import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:serial/serial.dart';
import 'package:trycatch/flights/replay_controller.dart';
import 'package:trycatch/settings/launch_site_store.dart';

const _fileSite = LaunchSite(
  name: 'Pad',
  latitude: 49.5,
  longitude: 16.5,
  altitudeMsl: 378,
);
const _selected = LaunchSite(
  name: 'Home',
  latitude: 50.0,
  longitude: 14.0,
  altitudeMsl: 250,
);

LaunchSite? _effective({
  required ReplayState replay,
  LaunchSite? selected,
}) {
  final container = ProviderContainer(overrides: [
    replayProvider.overrideWith(() => _StubReplay(replay)),
    currentLaunchSiteProvider.overrideWithValue(selected),
  ]);
  try {
    return container.read(effectiveLaunchSiteProvider);
  } finally {
    container.dispose();
  }
}

class _StubReplay extends ReplayController {
  final ReplayState initial;

  _StubReplay(this.initial);

  @override
  ReplayState build() => initial;
}

void main() {
  group('launchSiteFromHeader', () {
    test('maps a header launch ref to a site', () {
      const header = RecordingHeader(
        hasLaunchSite: true,
        launchLatitude: 49.5,
        launchLongitude: 16.5,
        launchMslM: 378,
        launchName: 'Pad',
      );
      final site = launchSiteFromHeader(header)!;
      expect(site.name, 'Pad');
      expect(site.latitude, closeTo(49.5, 1e-9));
      expect(site.longitude, closeTo(16.5, 1e-9));
      expect(site.altitudeMsl, closeTo(378, 1e-9));
    });

    test('null header or missing site yields null', () {
      expect(launchSiteFromHeader(null), isNull);
      expect(launchSiteFromHeader(const RecordingHeader()), isNull);
    });
  });

  group('effectiveLaunchSiteProvider', () {
    test('file site wins during an active replay', () {
      expect(
        _effective(
          replay: const ReplayState(
            filePath: 'a.bin',
            launchSite: _fileSite,
          ),
          selected: _selected,
        ),
        _fileSite,
      );
    });

    test('falls back to the selected site without a file site', () {
      expect(
        _effective(
          replay: const ReplayState(filePath: 'a.bin'),
          selected: _selected,
        ),
        _selected,
      );
    });

    test('uses the selected site outside a replay', () {
      expect(
        _effective(
          replay: const ReplayState(),
          selected: _selected,
        ),
        _selected,
      );
    });

    test('is null when neither exists', () {
      expect(
        _effective(replay: const ReplayState()),
        isNull,
      );
    });
  });
}
