import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:trycatch/ui/screens/dashboard_screen.dart';
import 'package:trycatch/state/tile_registry.dart';

/// Reproduction for "tiles only render in edit mode when a view has 2+".
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<void> pumpDashboard(WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(home: Scaffold(body: DashboardScreen())),
      ),
    );
    await tester.pumpAndSettle();
  }

  TileDescriptor fakeTile(String id, String label) => TileDescriptor(
        id: id,
        title: label,
        description: 'test',
        minSize: const Size(80, 60),
        builder: (context) => SizedBox.expand(
          child: Center(child: Text('${label.toUpperCase()} BODY')),
        ),
      );

  testWidgets('two-widget workspace renders outside edit mode',
      (tester) async {
    SharedPreferences.setMockInitialValues({
      'trycatch.workspaces': jsonEncode({
        'activeId': 'ws1',
        'workspaces': [
          {
            'id': 'ws1',
            'name': 'Test',
            'root': {
              'type': 'split',
              'id': 's1',
              'vertical': false,
              'ratio': 0.5,
              'a': {'type': 'leaf', 'tileId': 'l1', 'tileType': 'w1'},
              'b': {'type': 'leaf', 'tileId': 'l2', 'tileType': 'w2'},
            },
          },
        ],
      }),
    });

    final saved = List<TileDescriptor>.from(TileRegistry.all);
    TileRegistry.all.clear();
    TileRegistry.all.addAll([
      fakeTile('w1', 'One'),
      fakeTile('w2', 'Two'),
    ]);
    addTearDown(() {
      TileRegistry.all.clear();
      TileRegistry.all.addAll(saved);
    });

    await pumpDashboard(tester);

    // Live mode (edit off): both tile bodies and headers must be present.
    expect(find.text('ONE BODY'), findsOneWidget,
        reason: 'widget 1 body missing outside edit mode');
    expect(find.text('TWO BODY'), findsOneWidget,
        reason: 'widget 2 body missing outside edit mode');

    // Toggle edit mode on and confirm they still render.
    await tester.tap(find.text('Edit layout'));
    await tester.pumpAndSettle();
    expect(find.text('ONE BODY'), findsOneWidget);
    expect(find.text('TWO BODY'), findsOneWidget);
  });

  testWidgets('single-widget workspace renders outside edit mode',
      (tester) async {
    SharedPreferences.setMockInitialValues({
      'trycatch.workspaces': jsonEncode({
        'activeId': 'ws1',
        'workspaces': [
          {
            'id': 'ws1',
            'name': 'Test',
            'root': {'type': 'leaf', 'tileId': 'l1', 'tileType': 'w1'},
          },
        ],
      }),
    });

    final saved = List<TileDescriptor>.from(TileRegistry.all);
    TileRegistry.all.clear();
    TileRegistry.all.addAll([fakeTile('w1', 'One')]);
    addTearDown(() {
      TileRegistry.all.clear();
      TileRegistry.all.addAll(saved);
    });

    await pumpDashboard(tester);
    expect(find.text('ONE BODY'), findsOneWidget);
  });
}
