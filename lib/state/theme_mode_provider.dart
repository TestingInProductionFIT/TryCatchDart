import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../theme/app_colors.dart';

/// Riverpod view of the theme switch (layer 1).
///
/// `AppThemeMode.instance` remains the storage owner for now (layer 3
/// singleton below the provider scope); this provider mirrors it so UI
/// rebuilds via `watch` instead of `ValueListenableBuilder`, and so future
/// work can move persistence fully into Riverpod.
final themeModeProvider = NotifierProvider<ThemeModeStore, bool>(
  ThemeModeStore.new,
);

class ThemeModeStore extends Notifier<bool> {
  @override
  bool build() => AppThemeMode.instance.value;

  Future<void> setDark(bool dark) async {
    state = dark;
    await AppThemeMode.instance.setDark(dark);
  }
}
