import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../flights/recordings_screen.dart';
import '../settings/settings_screen.dart';
import '../workspaces/dashboard_screen.dart';
import 'monitor_screen.dart';
import 'router.dart';
import 'top_bar.dart';

/// Root layout: top bar on every screen + the active screen below it.
///
/// Screens live in an [IndexedStack] so switching is instant: every screen
/// stays mounted, and returning to a screen restores its state (map tiles,
/// channel-health history, scroll positions) instead of rebuilding the whole
/// subtree.
class AppShell extends ConsumerWidget {
  const AppShell({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final screen = ref.watch(appRouterProvider);

    return Scaffold(
      body: Column(
        children: [
          // NOTE: non-const on purpose — const children would not rebuild on
          // a dark-mode flip (AppColors resolves dynamically).
          TopBar(),
          Expanded(
            child: IndexedStack(
              index: screen.index,
              children: [
                DashboardScreen(),
                RecordingsScreen(),
                MonitorScreen(),
                SettingsScreen(),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
