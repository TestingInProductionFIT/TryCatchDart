import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:trycatch/services/prefs_keys.dart';
import 'package:trycatch/state/launch_site_store.dart';
import 'package:trycatch/ui/screens/settings_screen.dart';

Map<String, dynamic> _site(String name) => {
      'name': name,
      'latitude': 50.0,
      'longitude': 14.0,
      'altitudeMsl': 300.0,
    };

Future<LaunchSiteState> _loadWithPrefs(Map<String, dynamic> stored) async {
  SharedPreferences.setMockInitialValues({
    PrefsKeys.launchSites: jsonEncode(stored),
  });
  final container = ProviderContainer();
  try {
    return await container.read(launchSiteProvider.future);
  } finally {
    container.dispose();
  }
}

void main() {
  group('LaunchSiteStore saved-only invariant', () {
    test('adopts a stray selection into the presets', () async {
      final state = await _loadWithPrefs({
        'selected': _site('Idk'),
        'presets': [_site('Home')],
      });
      expect(state.selected?.name, 'Idk');
      expect(
        state.presets.map((p) => p.name).toSet(),
        {'Idk', 'Home'},
      );
    });

    test('null selection with presets falls through to the first', () async {
      final state = await _loadWithPrefs({
        'selected': null,
        'presets': [_site('Alpha'), _site('Beta')],
      });
      expect(state.selected?.name, 'Alpha');
    });

    test('duplicate preset names collapse', () async {
      final state = await _loadWithPrefs({
        'selected': _site('Home'),
        'presets': [_site('Home'), _site('Home')],
      });
      expect(state.presets.where((p) => p.name == 'Home').length, 1);
      expect(state.selected?.name, 'Home');
    });

    test('empty state stays empty (prompts adding a site)', () async {
      final state = await _loadWithPrefs({
        'selected': null,
        'presets': [],
      });
      expect(state.selected, isNull);
      expect(state.presets, isEmpty);
    });

    test('deleting the last preset clears the selection', () async {
      SharedPreferences.setMockInitialValues({
        PrefsKeys.launchSites: jsonEncode({
          'selected': _site('Solo'),
          'presets': [_site('Solo')],
        }),
      });
      final container = ProviderContainer();
      try {
        await container.read(launchSiteProvider.future);
        await container
            .read(launchSiteProvider.notifier)
            .deletePreset('Solo');
        final state = container.read(launchSiteProvider).value!;
        expect(state.presets, isEmpty);
        expect(state.selected, isNull);
      } finally {
        container.dispose();
      }
    });

    test('deleting the active preset falls through to another', () async {
      SharedPreferences.setMockInitialValues({
        PrefsKeys.launchSites: jsonEncode({
          'selected': _site('Beta'),
          'presets': [_site('Alpha'), _site('Beta')],
        }),
      });
      final container = ProviderContainer();
      try {
        await container.read(launchSiteProvider.future);
        await container
            .read(launchSiteProvider.notifier)
            .deletePreset('Beta');
        final state = container.read(launchSiteProvider).value!;
        expect(
          state.presets.map((p) => p.name).toList(),
          ['Alpha'],
        );
        expect(state.selected?.name, 'Alpha');
      } finally {
        container.dispose();
      }
    });
  });

  group('SettingsScreen', () {
    // Launch-site editing moved to the top-bar dialog; settings keeps
    // offline maps + appearance. A stray selection must still load cleanly.
    testWidgets('stray selection loads without throwing', (tester) async {
      SharedPreferences.setMockInitialValues({
        PrefsKeys.launchSites: jsonEncode({
          'selected': _site('Idk'),
          'presets': [],
        }),
      });
      await tester.pumpWidget(
        const ProviderScope(
          child: MaterialApp(
            home: Scaffold(body: SettingsScreen()),
          ),
        ),
      );
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(find.text('OFFLINE MAPS'), findsOneWidget);
    });
  });
}
