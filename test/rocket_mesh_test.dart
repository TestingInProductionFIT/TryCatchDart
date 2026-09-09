import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trycatch/theme/app_colors.dart';
import 'package:trycatch/workspaces/widgets/rocket_mesh.dart';
import 'package:vector_math/vector_math_64.dart';

/// Locks the Raketa.ork proportions (upper tube 0.5 m, fin tube 0.19 m,
/// Haack nose 0.165 m, Ø 66.8 mm) and the nose-cone pop / parachute
/// behaviour.
void main() {
  group('ork proportions', () {
    test('upper : cage : nose matches 0.5 : 0.19 : 0.165', () {
      final upper = RocketMesh.upperTubeLength;
      expect(RocketMesh.cageLength / upper, closeTo(0.19 / 0.5, 0.02));
      expect(RocketMesh.noseLength / upper, closeTo(0.165 / 0.5, 0.02));
    });

    test('airframe slenderness matches Ø 66.8 mm (L/D ~ 12.8)', () {
      final length = RocketMesh.baseExtent + 1.38; // fin bottoms → tip
      expect(length / (2 * RocketMesh.bodyRadius), closeTo(12.8, 0.5));
    });

    test('fins keep root == tip chord (rectangular)', () {
      expect(RocketMesh.finChord, greaterThan(0));
      // Chord occupies the lower part of the cage, like the .ork set at
      // the tube base (0.07 of 0.19 m).
      expect(RocketMesh.finChord / RocketMesh.cageLength,
          closeTo(0.07 / 0.19, 0.05));
    });

    test('baseExtent covers the fin bottoms below the cage', () {
      expect(RocketMesh.baseExtent, closeTo(0.77, 1e-9));
    });
  });

  group('nose cone pop', () {
    test('nose is pink with only the top 5 cm black', () {
      final nose =
          RocketMesh.triangles.where((t) => t.isNoseCone).toList();
      expect(nose, isNotEmpty);
      final black = nose
          .where((t) => t.color == const Color(0xFF232328))
          .toList();
      final pink = nose
          .where((t) => t.color == AppColors.pink)
          .toList();
      expect(black, isNotEmpty);
      expect(pink, isNotEmpty);
      // Black band height matches 5 cm at model scale.
      double minBlackY = double.infinity;
      for (final t in black) {
        for (final v in [t.a, t.b, t.c]) {
          if (v.y < minBlackY) minBlackY = v.y;
        }
      }
      const tipY = 1.38;
      expect(tipY - minBlackY,
          closeTo(RocketMesh.noseBlackLength, 0.04));
      // Every black tri sits above every pink one.
      double maxPinkY = -double.infinity;
      for (final t in pink) {
        for (final v in [t.a, t.b, t.c]) {
          if (v.y > maxPinkY) maxPinkY = v.y;
        }
      }
      expect(minBlackY, greaterThanOrEqualTo(maxPinkY - 0.04));
    });

    test('mesh() hides the cone but keeps the body', () {
      final full = RocketMesh.mesh().toList();
      final popped = RocketMesh.mesh(showNoseCone: false).toList();
      expect(popped.length, lessThan(full.length));
      expect(popped.any((t) => t.isNoseCone), isFalse);
      expect(full.any((t) => t.isNoseCone), isTrue);
    });

    test('bottom cap faces down, mouth cap faces up', () {
      // Bottom cap: down-facing fan closing the cage base.
      final down =
          RocketMesh.triangles.where((t) => t.normal.y < -0.99).toList();
      expect(down, isNotEmpty);
      for (final t in down) {
        for (final v in [t.a, t.b, t.c]) {
          expect(v.y, closeTo(-RocketMesh.baseExtent + 0.03, 1e-9));
        }
      }
      // Mouth cap: up-facing disk just inside the tube mouth.
      final caps =
          RocketMesh.triangles.where((t) => t.interiorCap).toList();
      expect(caps, isNotEmpty);
      for (final t in caps) {
        expect(t.normal.y, closeTo(1.0, 1e-9));
        for (final v in [t.a, t.b, t.c]) {
          expect(v.y, lessThan(RocketMesh.bodyTop));
          expect(v.y, greaterThan(RocketMesh.bodyTop - 0.05));
        }
      }
    });

    test('mouth cap shows only while popped', () {
      expect(RocketMesh.mesh().any((t) => t.interiorCap), isFalse);
      expect(
          RocketMesh.mesh(showNoseCone: false).any((t) => t.interiorCap),
          isTrue);
    });
  });

  group('parachute', () {
    test('gores alternate red/white vent → skirt', () {
      // One canopy quad band per gore: neighbouring gores differ.
      final bands = ParachuteMesh.bands;
      final gores = ParachuteMesh.goreCount;
      final quadsPerGore = bands * 2; // tris per band quad
      // First tri of each gore's first band carries the gore colour.
      final goreColors = <Color>[];
      for (var g = 0; g < gores; g++) {
        goreColors.add(ParachuteMesh.triangles[g * quadsPerGore].color);
      }
      for (var g = 0; g < gores; g++) {
        final expected = g.isEven ? ParachuteMesh.red : ParachuteMesh.white;
        expect(goreColors[g], expected, reason: 'gore $g');
      }
    });

    test('canopy is never culled (draws from both sides)', () {
      expect(ParachuteMesh.triangles, isNotEmpty);
      for (final t in ParachuteMesh.triangles) {
        expect(t.noCull, isTrue, reason: 'chute tri must skip culling');
      }
      // Fins keep the paired-face culling.
      final fin = RocketMesh.triangles.firstWhere((t) => t.doubleSided);
      expect(fin.noCull, isFalse);
    });

    test('apex has a vent hole, not a cap', () {
      var minAxisDist = double.infinity;
      for (final t in ParachuteMesh.triangles) {
        for (final v in [t.a, t.b, t.c]) {
          // Only canopy vertices above the skirt count (not shroud lines).
          if (v.y < ParachuteMesh.skirtY) continue;
          final d = Vector2(v.x, v.z).length;
          if (d < minAxisDist) minAxisDist = d;
        }
      }
      // Vent lip inner edge sits just inside the vent radius.
      expect(minAxisDist, greaterThan(0.04));
      expect(minAxisDist, lessThan(ParachuteMesh.ventRadius));
    });

    test('chute lives in an attach-relative world-up frame', () {
      // Origin at the shroud attach point: lines start ~0, canopy above.
      var minY = double.infinity;
      for (final t in ParachuteMesh.triangles) {
        for (final v in [t.a, t.b, t.c]) {
          if (v.y < minY) minY = v.y;
        }
      }
      expect(minY, closeTo(ParachuteMesh.attachY, 0.02));
      expect(ParachuteMesh.skirtY, greaterThan(ParachuteMesh.attachY));
      expect(ParachuteMesh.apexY, greaterThan(ParachuteMesh.skirtY));
    });
  });
}
