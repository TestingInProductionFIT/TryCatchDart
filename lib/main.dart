import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
// tray_manager 0.6+ native API (one TrayIcon object per icon, sync
// setters, per-item click listeners). Imported with a prefix: its Image,
// Menu and MenuItem clash with Flutter's widgets.
import 'package:tray_manager/tray_manager.dart' as tray;
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
            // Global accessibility opt-out: Windows semantics are always
            // on and its AXTree bridge spams
            // "Failed to update ui::AXTree" on telemetry-rate rebuilds.
            // The app keeps visual tooltips; it publishes no semantics.
            builder: (context, child) => ExcludeSemantics(child: child!),
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
    with WindowListener {
  /// Held for the app lifetime: garbage collection would release the
  /// native handle and remove the icon. Same for the attached menu.
  tray.TrayIcon? _trayIcon;
  // Write-only by design: the reference itself keeps the native menu alive.
  // ignore: unused_field
  tray.Menu? _trayMenu;

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
    _initDesktopLifecycle();
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    _trayIcon?.dispose();
    _trayIcon = null;
    _trayMenu = null;
    super.dispose();
  }

  Future<void> _initDesktopLifecycle() async {
    // 1. Intercept native close button clicks so the OS does not kill the process
    await windowManager.setPreventClose(true);

    // 2. Setup system tray icon and context menu
    await _setupSystemTray();
  }

  Future<void> _setupSystemTray() async {
    // NOTE: the icon is a StatusNotifierItem on Linux (needs a hosting
    // panel; clicks are never reported there — the panel opens the
    // registered menu itself). Every call is guarded individually so one
    // failing step can never abort the rest of the setup (a single shared
    // try/catch around setTooltip used to skip the icon + menu on Linux,
    // leaving no tray at all).
    final trayIcon = tray.TrayIcon.create();
    if (trayIcon == null) {
      debugPrint('System tray: TrayIcon.create() failed, skipping tray');
      return;
    }
    _trayIcon = trayIcon;
    trayIcon.addListener((event) {
      switch (event) {
        case tray.TrayIconClickedEvent():
        case tray.TrayIconDoubleClickedEvent():
          _showWindow();
        case tray.TrayIconRightClickedEvent():
          if (Platform.isLinux) return;
          _trayGuard('openContextMenu', () async {
            trayIcon.openContextMenu();
          });
      }
    });
    await _trayGuard('setIcon', () async {
      final iconPath = await _resolveTrayIconPath();
      if (iconPath == null) {
        debugPrint('System tray: no icon file found, skipping icon');
        return;
      }
      final image = tray.Image.fromFile(iconPath);
      if (image == null) {
        debugPrint('System tray: could not load $iconPath');
        return;
      }
      trayIcon.icon = image;
    });
    if (Platform.isLinux) {
      // Closest Linux equivalent of a tooltip: the indicator label.
      await _trayGuard('setTitle', () async => trayIcon.setTitle('TryCatch'));
    } else {
      await _trayGuard(
        'setTooltip',
        () async => trayIcon.setTooltip('TryCatch'),
      );
    }
    await _trayGuard('setContextMenu', () async {
      final menu = tray.Menu.create();
      if (menu == null) return;
      final showItem = tray.MenuItem.createWithLabelAndType(
        'Show TryCatch',
        tray.MenuItemType.normal,
      );
      if (showItem != null) {
        showItem.addListener((event) {
          if (event is tray.MenuItemClickedEvent) _showWindow();
        });
        menu.addItem(showItem);
      }
      menu.addSeparator();
      final quitItem = tray.MenuItem.createWithLabelAndType(
        'Quit TryCatch',
        tray.MenuItemType.normal,
      );
      if (quitItem != null) {
        quitItem.addListener((event) async {
          if (event is tray.MenuItemClickedEvent) {
            // Destroy bypasses preventClose and exits completely.
            await windowManager.destroy();
          }
        });
        menu.addItem(quitItem);
      }
      trayIcon.setContextMenu(menu);
      _trayMenu = menu;
    });
    await _trayGuard('setVisible', () async => trayIcon.setVisible(true));
  }

  Future<void> _showWindow() async {
    await windowManager.show();
    await windowManager.focus();
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
  Future<String?> _resolveTrayIconPath() async {
    final fileName = Platform.isWindows ? 'icon.ico' : 'icon.png';
    // Dev: repo root is the working directory.
    final dev = File('assets/$fileName');
    if (await dev.exists()) return dev.absolute.path;
    // Installed bundle: <exeDir>/data/flutter_assets/assets/<file>.
    try {
      final exeDir = File(Platform.resolvedExecutable).parent.path;
      final sep = Platform.pathSeparator;
      final bundled = File(
        '$exeDir${sep}data${sep}flutter_assets${sep}assets$sep$fileName',
      );
      if (await bundled.exists()) return bundled.path;
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
  Widget build(BuildContext context) {
    return widget.child;
  }
}
