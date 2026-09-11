import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:trycatch/state/workspace_controller.dart';

Future<ProviderContainer> _containerWith(List<String> names) async {
  SharedPreferences.setMockInitialValues({
    'trycatch.workspaces': jsonEncode({
      'activeId': 'ws1',
      'workspaces': [
        for (var i = 0; i < names.length; i++)
          {'id': 'ws${i + 1}', 'name': names[i], 'root': null},
      ],
    }),
  });
  final container = ProviderContainer();
  // Wait for the async store to load persisted state.
  await container.read(workspaceProvider.future);
  return container;
}

List<String> _names(ProviderContainer c) =>
    c.read(workspaceProvider).value!.workspaces.map((w) => w.name).toList();

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('workspace reorder', () {
    test('moveWorkspace moves to the requested final index', () async {
      final c = _containerWith(['A', 'B', 'C']);
      final container = await c;

      await container
          .read(workspaceProvider.notifier)
          .moveWorkspace('ws1', 2);
      expect(_names(container), ['B', 'C', 'A']);

      await container
          .read(workspaceProvider.notifier)
          .moveWorkspace('ws3', 0);
      expect(_names(container), ['C', 'B', 'A']);
      container.dispose();
    });

    test('moveWorkspace clamps and ignores unknown ids', () async {
      final container = await _containerWith(['A', 'B']);

      await container.read(workspaceProvider.notifier).moveWorkspace('ws1', 99);
      expect(_names(container), ['B', 'A']);

      await container.read(workspaceProvider.notifier).moveWorkspace('ws2', -5);
      // ws2 is now at index 0; moving to -5 (clamped 0) is a no-op.
      expect(_names(container), ['B', 'A']);

      await container.read(workspaceProvider.notifier).moveWorkspace('nope', 0);
      expect(_names(container), ['B', 'A']);
      container.dispose();
    });

    test('moveWorkspace keeps the active workspace', () async {
      final container = await _containerWith(['A', 'B', 'C']);
      // Active defaults to the first workspace (A / ws1).
      expect(
          container.read(workspaceProvider).value!.active?.id, 'ws1');

      await container
          .read(workspaceProvider.notifier)
          .moveWorkspace('ws1', 2);
      expect(
          container.read(workspaceProvider).value!.active?.id, 'ws1');
      expect(_names(container), ['B', 'C', 'A']);
      container.dispose();
    });

    test('moveWorkspace persists the new order', () async {
      final container = await _containerWith(['A', 'B', 'C']);
      await container
          .read(workspaceProvider.notifier)
          .moveWorkspace('ws1', 1);
      expect(_names(container), ['B', 'A', 'C']);

      // A fresh container loads the persisted order.
      final container2 = ProviderContainer();
      await container2.read(workspaceProvider.future);
      expect(
        container2.read(workspaceProvider).value!.workspaces.map((w) => w.name),
        ['B', 'A', 'C'],
      );
      container.dispose();
      container2.dispose();
    });

    test('reorderWorkspace follows ReorderableListView semantics', () async {
      final container = await _containerWith(['A', 'B', 'C']);
      // Drag A (0) after C: Reorderable passes newIndex 3.
      await container
          .read(workspaceProvider.notifier)
          .reorderWorkspace(0, 3);
      expect(_names(container), ['B', 'C', 'A']);
      container.dispose();
    });
  });
}
