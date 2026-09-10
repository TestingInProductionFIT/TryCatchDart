import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:serial/serial.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:trycatch/state/telemetry_provider.dart';
import 'package:trycatch/ui/components/brand_mark.dart';
import 'package:trycatch/ui/components/top_bar.dart';
import 'package:trycatch/ui/screens/router.dart';

/// The top-left brand is the home affordance: tapping logo + wordmark
/// returns to the Dashboard from any screen.
void main() {
  testWidgets('tapping the brand goes back to the dashboard', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          availablePortsProvider
              .overrideWith((ref) => Stream.value(const <String>[])),
          serialStatusProvider.overrideWith(
              (ref) => Stream.value(const SerialWorkerStatus())),
          telemetryStreamProvider.overrideWith(
              (ref) => Stream<TelemetryPacket>.empty()),
          linkStatsStreamProvider
              .overrideWith((ref) => Stream<LinkStats>.empty()),
        ],
        child: MaterialApp(
          // ignore: prefer_const_constructors — fresh instances on purpose.
          home: Scaffold(
            body: Column(
              children: [
                TopBar(),
                const Expanded(child: SizedBox()),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(tester.takeException(), isNull);

    final container =
        ProviderScope.containerOf(tester.element(find.byType(TopBar)));
    container.read(appRouterProvider.notifier).go(AppScreen.settings);
    await tester.pump();
    expect(container.read(appRouterProvider), AppScreen.settings);

    await tester.tap(find.byType(BrandMark));
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(container.read(appRouterProvider), AppScreen.dashboard);
  });
}
