import 'package:flutter_test/flutter_test.dart';
import 'package:trycatch/src/atmosphere/pressure.dart';

void main() {
  group('pressurePaFromMsl', () {
    test('is 101325 Pa at sea level', () {
      expect(pressurePaFromMsl(0), closeTo(101325.0, 0.5));
    });

    test('recovers the imported CRC flight pad pressure', () {
      // Old logger: 96870.9 Pa on the pad (~378 m MSL by the same model).
      expect(pressurePaFromMsl(378.4), closeTo(96870.9, 10));
    });

    test('recovers the imported CRC flight apogee pressure', () {
      // Old logger: 91330.0 Pa at 488.6 m AGL.
      expect(pressurePaFromMsl(378.4 + 488.6), closeTo(91330.0, 15));
    });

    test('falls monotonically with altitude', () {
      expect(pressurePaFromMsl(500), lessThan(pressurePaFromMsl(0)));
      expect(pressurePaFromMsl(-10), greaterThan(pressurePaFromMsl(0)));
    });

    test('returns 0 instead of NaN above the model ceiling', () {
      expect(pressurePaFromMsl(50000), 0);
    });
  });

  group('pressurePaFromBaro', () {
    test('adds the site MSL altitude to the AGL reading', () {
      expect(
        pressurePaFromBaro(100, siteMslM: 300),
        pressurePaFromMsl(400),
      );
    });

    test('defaults to a sea-level site', () {
      expect(pressurePaFromBaro(0), closeTo(101325.0, 0.5));
    });
  });
}
