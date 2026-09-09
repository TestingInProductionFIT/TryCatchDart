import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../theme/app_colors.dart';
import 'widget_registry.dart';
import 'workspace_controller.dart';
import 'workspace_grid.dart';
import 'workspace_models.dart';

/// The main screen: workspace tab strip + the interactive widget grid.
class DashboardScreen extends ConsumerStatefulWidget {
  const DashboardScreen({super.key});

  @override
  ConsumerState<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends ConsumerState<DashboardScreen> {
  bool _editMode = false;

  @override
  Widget build(BuildContext context) {
    final wsState = ref.watch(workspaceProvider);
    final workspaces = wsState.value?.workspaces ?? const <Workspace>[];
    final activeId = wsState.value?.activeId ?? '';

    return CallbackShortcuts(
      bindings: {
        for (var i = 0; i < workspaces.length && i < 9; i++)
          SingleActivator(LogicalKeyboardKey(0x31 + i), control: true): () {
            ref.read(workspaceProvider.notifier).setActive(workspaces[i].id);
          },
      },
      child: FocusScope(
        autofocus: true,
        child: Column(
          children: [
            _buildTabStrip(context, workspaces, activeId),
            Expanded(
              child: WorkspaceGrid(editMode: _editMode),
            ),
          ],
        ),
      ),
    );
  }

  // ── Tab strip ───────────────────────────────────────────────────────────────

  Widget _buildTabStrip(
    BuildContext context,
    List<Workspace> workspaces,
    String activeId,
  ) {
    return Container(
      height: AppDimens.workspaceTabsHeight,
      padding: const EdgeInsets.symmetric(horizontal: AppDimens.outerPadding),
      decoration: BoxDecoration(
        color: AppColors.background,
        border: Border(bottom: BorderSide(color: AppColors.border)),
      ),
      child: Row(
        children: [
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  for (final ws in workspaces)
                    _buildTab(context, ws, ws.id == activeId),
                  _StripButton(
                    icon: Icons.add,
                    tooltip: 'New workspace',
                    onTap: () => _createWorkspaceDialog(context),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(width: 8),
          _StripToggle(
            icon: _editMode ? Icons.check : Icons.edit_outlined,
            label: _editMode ? 'Done' : 'Edit layout',
            active: _editMode,
            onTap: () => setState(() => _editMode = !_editMode),
          ),
          // Layout tools only make sense while editing; keep the strip clean
          // during a live session.
          if (_editMode) ...[
            const SizedBox(width: 6),
            _StripToggle(
              icon: Icons.dashboard_customize_outlined,
              label: 'Add widget',
              active: false,
              onTap: () => showWidgetPicker(context, ref),
            ),
            const SizedBox(width: 6),
            _StripToggle(
              icon: Icons.restart_alt,
              label: 'Reset',
              active: false,
              onTap: () => _confirmReset(context),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildTab(BuildContext context, Workspace ws, bool active) {
    final canDelete =
        (ref.read(workspaceProvider).value?.workspaces.length ?? 1) > 1;

    // Full strip height so the active underline sits flush on the strip's
    // bottom hairline and every tab aligns identically.
    return Container(
      height: double.infinity,
      margin: const EdgeInsets.only(right: 4),
      decoration: active
          ? BoxDecoration(
              border: Border(
                bottom: BorderSide(color: AppColors.pink, width: 2.5),
              ),
            )
          : null,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: InkWell(
          // Renaming lives in the right-click menu only — double-click is
          // reserved for canvas interactions, not the tab strip.
          onTap: () => ref.read(workspaceProvider.notifier).setActive(ws.id),
          onSecondaryTapUp: (details) =>
              _workspaceContextMenu(context, ws, details.globalPosition),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  ws.name,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: active ? FontWeight.w700 : FontWeight.w500,
                    color: active ? AppColors.foreground : AppColors.mutedForeground,
                  ),
                ),
                if (_editMode && canDelete) ...[
                  const SizedBox(width: 6),
                  InkWell(
                    onTap: () => ref.read(workspaceProvider.notifier).deleteWorkspace(ws.id),
                    child: Icon(Icons.close, size: 13, color: AppColors.mutedForeground),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _workspaceContextMenu(
    BuildContext context,
    Workspace ws,
    Offset position,
  ) {
    final notifier = ref.read(workspaceProvider.notifier);
    final overlay =
        Overlay.of(context).context.findRenderObject() as RenderBox;
    showMenu(
      context: context,
      position: RelativeRect.fromLTRB(
        position.dx,
        position.dy,
        overlay.size.width - position.dx,
        overlay.size.height - position.dy,
      ),
      items: [
        PopupMenuItem(
          value: 'rename',
          child: const _MenuRow(icon: Icons.edit, label: 'Rename'),
        ),
        PopupMenuItem(
          value: 'duplicate',
          child: const _MenuRow(icon: Icons.copy, label: 'Duplicate'),
        ),
        if ((ref.read(workspaceProvider).value?.workspaces.length ?? 0) > 1)
          PopupMenuItem(
            value: 'delete',
            child: _MenuRow(icon: Icons.delete_outline, label: 'Delete', danger: true),
          ),
      ],
    ).then((value) {
      if (!mounted) return;
      switch (value) {
        case 'rename':
          _renameWorkspaceDialog(this.context, ws);
        case 'duplicate':
          notifier.duplicateWorkspace(ws.id);
        case 'delete':
          notifier.deleteWorkspace(ws.id);
      }
    });
  }

  // ── Dialogs ─────────────────────────────────────────────────────────────────

  Future<void> _createWorkspaceDialog(BuildContext context) =>
      _nameDialog(context, 'New workspace', 'Prep 2',
          (name) => ref.read(workspaceProvider.notifier).createWorkspace(name));

  Future<void> _renameWorkspaceDialog(BuildContext context, Workspace ws) =>
      _nameDialog(context, 'Rename workspace', ws.name,
          (name) => ref.read(workspaceProvider.notifier).renameWorkspace(ws.id, name));

  Future<void> _nameDialog(
    BuildContext context,
    String title,
    String initial,
    ValueChanged<String> onDone,
  ) {
    final controller = TextEditingController(text: initial);
    return showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(title, style: const TextStyle(fontSize: 16)),
        content: TextField(
          controller: controller,
          autofocus: true,
          onSubmitted: (value) {
            if (value.trim().isNotEmpty) onDone(value.trim());
            Navigator.of(dialogContext).pop();
          },
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              if (controller.text.trim().isNotEmpty) {
                onDone(controller.text.trim());
              }
              Navigator.of(dialogContext).pop();
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

  Future<void> _confirmReset(BuildContext context) {
    return showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Reset all layouts?'),
        content: const Text(
          'This restores the factory workspaces and discards every custom '
          'arrangement. This cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppColors.destructive),
            onPressed: () {
              ref.read(workspaceProvider.notifier).resetToDefaults();
              Navigator.of(dialogContext).pop();
            },
            child: const Text('Reset'),
          ),
        ],
      ),
    );
  }

}

/// The add-widget sheet. With [splitWidgetId] the picked widget replaces that
/// tile by splitting it into two; otherwise it splits the largest tile.
void showWidgetPicker(
  BuildContext context,
  WidgetRef ref, {
  String? splitWidgetId,
}) {
  showModalBottomSheet(
    context: context,
    backgroundColor: AppColors.card,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(AppDimens.radius)),
    ),
    builder: (sheetContext) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
            child: Row(
              children: [
                Container(
                  width: 7,
                  height: 7,
                  decoration: BoxDecoration(
                    color: AppColors.pink,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  (splitWidgetId == null ? 'Add a widget' : 'Split tile — pick widget')
                      .toUpperCase(),
                  style: AppText.microLabel,
                ),
              ],
            ),
          ),
          Flexible(
            child: ListView(
              shrinkWrap: true,
              padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
              children: [
                for (final descriptor in WidgetRegistry.all)
                  ListTile(
                    dense: true,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(AppDimens.radiusSmall),
                    ),
                    leading: const Icon(Icons.widgets_outlined, size: 20),
                    title: Text(descriptor.title,
                        style: const TextStyle(
                            fontSize: 13.5, fontWeight: FontWeight.w600)),
                    subtitle: Text(descriptor.description,
                        style: const TextStyle(fontSize: 12)),
                    onTap: () {
                      Navigator.of(sheetContext).pop();
                      ref
                          .read(workspaceProvider.notifier)
                          .addWidget(descriptor.id, splitWidgetId: splitWidgetId);
                    },
                  ),
              ],
            ),
          ),
        ],
      ),
    ),
  );
}

// ── Small strip building blocks ───────────────────────────────────────────────

class _StripButton extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  const _StripButton({required this.icon, required this.tooltip, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: Tooltip(
        message: tooltip,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(AppDimens.radiusSmall),
          child: Padding(
            padding: const EdgeInsets.all(6),
            child: Icon(icon, size: 16, color: AppColors.mutedForeground),
          ),
        ),
      ),
    );
  }
}

class _StripToggle extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool active;
  final VoidCallback? onTap;

  const _StripToggle({
    required this.icon,
    required this.label,
    required this.active,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: Material(
        color: active ? AppColors.pink : AppColors.card,
        shape: StadiumBorder(
          side: BorderSide(
              color: active ? AppColors.pink : AppColors.border),
        ),
        child: InkWell(
          onTap: onTap,
          customBorder: const StadiumBorder(),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  icon,
                  size: 14,
                  color: active ? Colors.white : AppColors.foreground,
                ),
                const SizedBox(width: 6),
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: active ? Colors.white : AppColors.foreground,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _MenuRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool danger;

  const _MenuRow({required this.icon, required this.label, this.danger = false});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon,
            size: 16, color: danger ? AppColors.destructive : AppColors.mutedForeground),
        const SizedBox(width: 8),
        Text(
          label,
          style: TextStyle(
              fontSize: 13, color: danger ? AppColors.destructive : AppColors.foreground),
        ),
      ],
    );
  }
}
