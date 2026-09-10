import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:trycatch/ui/screens/dashboard_screen.dart';

/// Guards the Windows AXTree bridge against orphaned tooltip overlay nodes
/// (flutter/flutter#182444): adjacent bare Tooltips absorbed into one
/// semantics node drop all but the first overlay-portal identifier, and the
/// engine then rejects every update ("Nodes left pending").
///
/// What it pins: every workspace tab keeps its own tooltip node. (Today this
/// holds via each tab's tappable `InkWell`; the test fails if a refactor
/// ever leaves adjacent bare anchors sharing one scrollable item.)
///
/// NOTE: only the tab strip is covered. The recordings `GridView` cannot be
/// pumped meaningfully in widget tests — `initState` always runs in the
/// fake-async zone (verified: zone identity differs even when `pumpWidget`
/// is called inside `runAsync`), where real filesystem IO (`path_provider`,
/// `Directory.list`) stalls permanently. Covering it would need the scan's
/// file access abstracted behind an injectable service.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('dashboard tabs keep one tooltip node each', (tester) async {
    SharedPreferences.setMockInitialValues({
      'trycatch.workspaces': jsonEncode({
        'activeId': 'ws1',
        'workspaces': [
          for (var i = 0; i < 3; i++)
            {
              'id': 'ws${i + 1}',
              'name': ['Alpha', 'Beta', 'Gamma'][i],
              'root': null,
            },
        ],
      }),
    });

    final handle = tester.ensureSemantics();
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(home: Scaffold(body: DashboardScreen())),
      ),
    );
    await tester.pumpAndSettle();

    final owner =
        RendererBinding.instance.renderViews.first.owner!.semanticsOwner!;
    final hits = <String, Set<int>>{'Alpha': {}, 'Beta': {}, 'Gamma': {}};
    void visit(SemanticsNode node) {
      final tooltip = node.getSemanticsData().tooltip;
      if (tooltip.isNotEmpty) {
        for (final name in hits.keys) {
          if (tooltip.contains(name)) hits[name]!.add(node.id);
        }
      }
      node.visitChildren((child) {
        visit(child);
        return true;
      });
    }

    visit(owner.rootSemanticsNode!);

    for (final entry in hits.entries) {
      expect(
        entry.value,
        hasLength(1),
        reason: 'tab "${entry.key}" tooltip must live on exactly one node',
      );
    }
    final ids = hits.values.expand((s) => s).toSet();
    expect(
      ids,
      hasLength(3),
      reason:
          'each tab tooltip needs its own semantics node — '
          'merged tooltip anchors orphan overlay children on Windows '
          '(flutter/flutter#182444)',
    );
    handle.dispose();
  });
}
