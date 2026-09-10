import 'package:flutter_test/flutter_test.dart';
import 'package:trycatch/state/launch_site_store.dart';
import 'package:trycatch/ui/tiles/shared/map_tiles.dart';

void main() {
  group('tile URL builders', () {
    test('street URLs use Esri World Street Map (no subdomains)', () {
      expect(streetTileUrl(10, 20, 15),
          'https://server.arcgisonline.com/ArcGIS/rest/services/World_Street_Map/MapServer/tile/15/20/10');
      expect(streetTileUrl(11, 20, 15),
          'https://server.arcgisonline.com/ArcGIS/rest/services/World_Street_Map/MapServer/tile/15/20/11');
    });

    test('satellite URLs carry x/y/z in Esri order', () {
      expect(satelliteTileUrl(123, 456, 15),
          'https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/15/456/123');
    });

    test('precache count scales with sites', () {
      const site = LaunchSite(
          name: 'pad', latitude: 50.0, longitude: 14.0, altitudeMsl: 200);
      final one = precacheTileCount([site]);
      expect(one, greaterThan(0));
      expect(precacheTileCount([site, site]), one * 2);
      expect(precacheTileCount(const []), 0);
    });
  });
}
