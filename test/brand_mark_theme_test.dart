import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trycatch/theme/app_colors.dart';
import 'package:trycatch/ui/components/brand_mark.dart';

/// The top-bar wordmark must follow theme flips (a cached color would leave
/// it stuck in the old palette). The tree is built fresh on every flip,
/// mirroring main.dart (a fully-const tree would freeze by identity — see
/// top_bar_theme_test.dart).
void main() {
  testWidgets('wordmark color follows the theme', (tester) async {
    final wasDark = AppThemeMode.instance.value;
    AppThemeMode.instance.value = false;
    try {
      await tester.pumpWidget(
        ValueListenableBuilder<bool>(
          valueListenable: AppThemeMode.instance,
          builder: (_, isDark, _) => MaterialApp(
            theme: ThemeData(
              brightness: isDark ? Brightness.dark : Brightness.light,
            ),
            // ignore: prefer_const_constructors — fresh instances on purpose.
            home: Scaffold(body: BrandMark()),
          ),
        ),
      );
      await tester.pump();
      final lightColor =
          tester.widget<Text>(find.text('{TryCatch}')).style!.color;
      expect(lightColor, AppColors.foreground);

      AppThemeMode.instance.value = true;
      await tester.pump();
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
