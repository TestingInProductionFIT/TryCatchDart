import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

import './core/app_config.dart';
import './ui/screens/app_shell.dart';
import './state/telemetry_provider.dart';
import './theme/app_colors.dart';
import './theme/app_theme.dart';

import 'package:serial/serial.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await windowManager.ensureInitialized();
  await AppThemeMode.instance.load();

  // Spawn the background serial worker isolate before the UI starts.
  // The worker begins scanning for ports immediately.
  final worker = await SerialWorker.spawn();

  const windowOptions = WindowOptions(
    size: Size(AppConfig.windowInitialWidth, AppConfig.windowInitialHeight),
    minimumSize: Size(AppConfig.windowMinWidth, AppConfig.windowMinHeight),
    center: true,
    title: 'TryCatch',
  );

  windowManager.waitUntilReadyToShow(windowOptions, () async {
    await windowManager.show();
    await windowManager.maximize();
    await windowManager.focus();
  });

  runApp(
    ProviderScope(
      overrides: [
        // Inject the live worker handle into the provider graph.
        // All providers that depend on serialWorkerProvider will use this instance.
        serialWorkerProvider.overrideWithValue(worker),
      ],
      child: AppLifecycleWrapper(
        // Rebuilds MaterialApp on a dark-mode flip; every AppColors getter
        // resolves the active palette, so the whole tree follows.
        child: ValueListenableBuilder<bool>(
          valueListenable: AppThemeMode.instance,
          builder: (_, isDark, _) => MaterialApp(
            debugShowCheckedModeBanner: false,
            themeMode: ThemeMode.light,
            theme: buildAppTheme(dark: isDark),
            // NOTE: intentionally non-const — a const home would freeze the
            // whole subtree across dark-mode flips (AppColors is dynamic).
            home: AppShell(),
          ),
        ),
      ),
    ),
  );
}

class AppLifecycleWrapper extends StatefulWidget {
  final Widget child;
  const AppLifecycleWrapper({super.key, required this.child});

  @override
  State<AppLifecycleWrapper> createState() => _AppLifecycleWrapperState();
}

class _AppLifecycleWrapperState extends State<AppLifecycleWrapper>
    with WindowListener, TrayListener {
  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
    trayManager.addListener(this);
    _initDesktopLifecycle();
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    trayManager.removeListener(this);
    super.dispose();
  }

  Future<void> _initDesktopLifecycle() async {
    // 1. Intercept native close button clicks so the OS does not kill the process
    await windowManager.setPreventClose(true);

    // 2. Setup system tray icon and context menu
    await _setupSystemTray();
  }

  Future<void> _setupSystemTray() async {
    // NOTE: tray_manager's Linux backend only implements destroy / setIcon /
    // setTitle / setContextMenu (no setToolTip, no popUpContextMenu — the
    // AppIndicator shows its registered menu by itself). Every call is
    // guarded individually so one unsupported method can never abort the
    // rest of the setup (a single shared try/catch around setToolTip used
    // to skip setIcon + setContextMenu on Linux, leaving no tray at all).
    await _trayGuard('setIcon', () async {
      final iconPath = _resolveTrayIconPath();
      if (iconPath != null) {
        await trayManager.setIcon(iconPath);
      } else {
        debugPrint('System tray: no icon file found, skipping setIcon');
      }
    });
    if (Platform.isLinux) {
      // Closest Linux equivalent of a tooltip: the indicator label.
      await _trayGuard('setTitle', () => trayManager.setTitle('TryCatch'));
    } else {
      await _trayGuard('setToolTip', () => trayManager.setToolTip('TryCatch'));
    }
    await _trayGuard('setContextMenu', () async {
      await trayManager.setContextMenu(
        Menu(
          items: [
            MenuItem(key: 'show_app', label: 'Show TryCatch'),
            MenuItem.separator(),
            MenuItem(key: 'quit_app', label: 'Quit TryCatch'),
          ],
        ),
      );
    });
  }

  Future<void> _trayGuard(String what, Future<void> Function() call) async {
    try {
      await call();
    } catch (e) {
      debugPrint('System tray: $what failed: $e');
    }
  }

  /// Absolute tray-icon path: `flutter run` uses the repo-relative asset
  /// (CWD is the project root), while an installed/built bundle resolves
  /// next to the executable under `data/flutter_assets/`. Returns `null`
  /// when neither exists so the caller can skip `setIcon` (AppIndicator
  /// needs a real file, not a bundled asset key).
  String? _resolveTrayIconPath() {
    final fileName = Platform.isWindows ? 'icon.ico' : 'icon.png';
    // Dev: repo root is the working directory.
    final dev = File('assets/$fileName');
    if (dev.existsSync()) return dev.absolute.path;
    // Installed bundle: <exeDir>/data/flutter_assets/assets/<file>.
    try {
      final exeDir = File(Platform.resolvedExecutable).parent.path;
      final sep = Platform.pathSeparator;
      final bundled =
          File('$exeDir${sep}data${sep}flutter_assets${sep}assets$sep$fileName');
      if (bundled.existsSync()) return bundled.path;
    } catch (_) {
      // Fall through to null.
    }
    return null;
  }

  // Called whenever the user clicks the window close (X) button
  @override
  void onWindowClose() async {
    // Hide to tray instead of exiting
    if (await windowManager.isPreventClose()) {
      await windowManager.hide();
    }
  }

  @override
  void onTrayIconMouseDown() async {
    await windowManager.show();
    await windowManager.focus();
  }

  @override
  void onTrayIconRightMouseDown() {
    // Linux/AppIndicator shows the menu registered via setContextMenu by
    // itself — popUpContextMenu is not implemented there and would only
    // throw MissingPluginException.
    if (Platform.isLinux) return;
    _trayGuard('popUpContextMenu', () async {
      await trayManager.popUpContextMenu();
    });
  }

  @override
  void onTrayMenuItemClick(MenuItem menuItem) async {
    if (menuItem.key == 'show_app') {
      await windowManager.show();
      await windowManager.focus();
    } else if (menuItem.key == 'quit_app') {
      // Destroy the window bypasses preventClose and exits the app completely
      await windowManager.destroy();
    }
  }

  @override
  Widget build(BuildContext context) {
    return widget.child;
  }
}
