import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:serial/serial.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:trycatch/state/telemetry_provider.dart';
import 'package:trycatch/theme/app_colors.dart';
import 'package:trycatch/ui/components/top_bar.dart';

/// Regression test: the top-bar wordmark froze in one palette across theme
/// flips because `const` wrappers (Padding/BrandMark) are identical widget
/// instances across builds, so the framework skips rebuilding the subtree.
/// Pumps the real TopBar (worker-backed streams overridden) and flips the
/// theme exactly like main.dart does.
void main() {
  testWidgets('top bar follows the theme', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final wasDark = AppThemeMode.instance.value;
    AppThemeMode.instance.value = false;
    try {
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
          child: ValueListenableBuilder<bool>(
            valueListenable: AppThemeMode.instance,
            builder: (_, isDark, _) => MaterialApp(
              theme: ThemeData(
                brightness: isDark ? Brightness.dark : Brightness.light,
              ),
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
        ),
      );
      await tester.pump();
      expect(tester.takeException(), isNull);
      final lightColor =
          tester.widget<Text>(find.text('{TryCatch}')).style!.color;
      expect(lightColor, AppColors.foreground);

      AppThemeMode.instance.value = true;
      await tester.pump();
      expect(tester.takeException(), isNull);
      final darkColor =
          tester.widget<Text>(find.text('{TryCatch}')).style!.color;
      expect(darkColor, AppColors.foreground);
      expect(darkColor, isNot(lightColor));
    } finally {
      AppThemeMode.instance.value = wasDark;
      await tester.pump();
    }
  });
}
