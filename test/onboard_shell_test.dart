import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trycatch/ui/screens/tile_leaf_scope.dart';
import 'package:trycatch/ui/tiles/shared/flight_3d_shell.dart';

/// Locks the onboard shell contract: fixed zoom, spin around the rocket's
/// long axis only (vertical drags do nothing), double-tap recenters — while
/// the other modes keep zooming and orbiting the shared angles.
void main() {
  testWidgets('onboard blocks zoom and tilt, spins on one axis',
      (tester) async {
    await tester.pumpWidget(
      const ProviderScope(
        child: MaterialApp(home: Scaffold(body: _ShellHarness())),
      ),
    );
    final state =
        tester.state<_ShellHarnessState>(find.byType(_ShellHarness));
    state.setShellMode(FlightCameraMode.onboard);
    await tester.pump();

    // Zoom is fixed: wheel factors never land.
    state.zoomBy(2.0);
    state.zoomBy(0.5);
    expect(state.zoom, 1.0);

    // Vertical drags do nothing; horizontal drags spin the gaze.
    state.orbitBy(const Offset(0, 50));
    state.orbitBy(const Offset(30, -40));
    expect(state.onboardAzimuthDeg, closeTo(348.0, 1e-9));

    // Double-tap recenters the spin.
    state.resetZoom();
    expect(state.onboardAzimuthDeg, 0.0);
    expect(state.zoom, 1.0);

    // Other modes are unaffected: chase still zooms.
    state.setShellMode(FlightCameraMode.chase);
    state.zoomBy(2.0);
    expect(state.zoom, 2.0);

    // Unmount so the shell's orbit ticker stops with the widget.
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
  });

  testWidgets('shell restores the persisted leaf mode once', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Scaffold(
            body: TileLeafScope.fromSettings(
              tileId: 'leaf1',
              settings: const {leafCameraModeKey: 'onboard'},
              onCameraMode: (_) {},
              child: const _ShellHarness(),
            ),
          ),
        ),
      ),
    );
    final state =
        tester.state<_ShellHarnessState>(find.byType(_ShellHarness));
    expect(state.mode, FlightCameraMode.onboard);

    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
  });

  testWidgets('shell reports mode changes back to the leaf', (tester) async {
    final reported = <FlightCameraMode>[];
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Scaffold(
            body: TileLeafScope.fromSettings(
              tileId: 'leaf1',
              settings: const {},
              onCameraMode: reported.add,
              child: const _ShellHarness(),
            ),
          ),
        ),
      ),
    );
    final state =
        tester.state<_ShellHarnessState>(find.byType(_ShellHarness));
    expect(state.mode, FlightCameraMode.chase);

    state.setShellMode(FlightCameraMode.orbit);
    expect(reported, [FlightCameraMode.orbit]);

    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
  });
}

class _ShellHarness extends ConsumerStatefulWidget {
  const _ShellHarness();

  @override
  ConsumerState<_ShellHarness> createState() => _ShellHarnessState();
}

class _ShellHarnessState extends ConsumerState<_ShellHarness>
    with Flight3dShellState {
  @override
  Widget build(BuildContext context) => const SizedBox();
}
