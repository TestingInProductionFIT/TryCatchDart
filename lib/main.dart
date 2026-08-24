import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

import 'dashboard_view.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await windowManager.ensureInitialized();

  const windowOptions = WindowOptions(
    size: Size(1280, 800),
    minimumSize: Size(1024, 600),
    center: true,
    fullScreen: true,
    title: '{TryCatch}',
  );

  windowManager.waitUntilReadyToShow(windowOptions, () async {
    await windowManager.setFullScreen(true);
    await windowManager.show();
    await windowManager.focus();
  });

  runApp(
    const ProviderScope(
      child: AppLifecycleWrapper(
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          home: DashboardView(),
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
    try {
      await trayManager.setToolTip('{TryCatch}');

      await trayManager.setIcon(
        Platform.isWindows ? 'assets/icon.ico' : 'assets/icon.png',
      );

      await trayManager.setContextMenu(
        Menu(
          items: [
            MenuItem(key: 'show_app', label: 'Show {TryCatch}'),
            MenuItem.separator(),
            MenuItem(key: 'quit_app', label: 'Quit {TryCatch}'),
          ],
        ),
      );
    } catch (e) {
      debugPrint('Failed to initialize system tray: $e');
    }
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
    trayManager.popUpContextMenu();
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
