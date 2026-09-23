import 'package:flutter_test/flutter_test.dart';
import 'package:trycatch/services/elevation_service.dart';

void main() {
  test('tile center round-trips through its own key', () {
    for (final (lat, lon) in [
      (50.0755, 14.4378),
      (-33.8688, 151.2093),
      (0.5, -0.5),
    ]) {
      final key = elevationTileKey(lat, lon);
      final center = elevationTileCenter(key);
      // The centre of a tile lies inside that same tile.
      expect(elevationTileKey(center.latitude, center.longitude), key);
    }
  });
}
