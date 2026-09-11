import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../state/launch_site_store.dart';
import '../../state/telemetry_store.dart';
import '../../theme/app_colors.dart';
import '../tiles/shared/map_tiles.dart';

/// Opens the launch site configuration dialog.
Future<void> showLaunchSiteDialog(BuildContext context) {
  return showDialog(
    context: context,
    builder: (dialogContext) => const AlertDialog(
      title: Text('Launch site', style: TextStyle(fontSize: 16)),
      content: _LaunchSiteDialogBody(),
      actions: [_CloseButton()],
    ),
  );
}

class _CloseButton extends StatelessWidget {
  const _CloseButton();

  @override
  Widget build(BuildContext context) {
    return TextButton(
      onPressed: () => Navigator.of(context).pop(),
      child: const Text('Close'),
    );
  }
}

class _LaunchSiteDialogBody extends ConsumerStatefulWidget {
  const _LaunchSiteDialogBody();

  @override
  ConsumerState<_LaunchSiteDialogBody> createState() =>
      _LaunchSiteDialogBodyState();
}

class _LaunchSiteDialogBodyState extends ConsumerState<_LaunchSiteDialogBody> {
  final _name = TextEditingController();
  final _lat = TextEditingController();
  final _lon = TextEditingController();
  final _alt = TextEditingController();
  String? _error;

  /// Form mode: `false` shows the saved list, `true` the add/edit form.
  bool _showForm = false;

  /// Original preset name when editing (`null` when adding a new site).
  String? _editOriginal;

  @override
  void dispose() {
    _name.dispose();
    _lat.dispose();
    _lon.dispose();
    _alt.dispose();
    super.dispose();
  }

  void _openAdd() {
    setState(() {
      _showForm = true;
      _editOriginal = null;
      _error = null;
      _name.clear();
      _lat.clear();
      _lon.clear();
      _alt.clear();
    });
  }

  void _openEdit(LaunchSite preset) {
    setState(() {
      _showForm = true;
      _editOriginal = preset.name;
      _error = null;
      _fill(preset);
    });
  }

  void _closeForm() {
    setState(() {
      _showForm = false;
      _editOriginal = null;
      _error = null;
    });
  }

  void _fill(LaunchSite site) {
    _name.text = site.name;
    _lat.text = site.latitude.toStringAsFixed(6);
    _lon.text = site.longitude.toStringAsFixed(6);
    _alt.text = site.altitudeMsl.toStringAsFixed(1);
  }

  double? _num(TextEditingController c) =>
      double.tryParse(c.text.trim().replaceAll(',', '.'));

  LaunchSite? _parseManual() {
    final name = _name.text.trim();
    final lat = _num(_lat);
    final lon = _num(_lon);
    final alt = _num(_alt) ?? 0;
    if (name.isEmpty) {
      setState(() => _error = 'Give the site a name.');
      return null;
    }
    if (lat == null || lat < -90 || lat > 90) {
      setState(() => _error = 'Latitude must be between -90 and 90.');
      return null;
    }
    if (lon == null || lon < -180 || lon > 180) {
      setState(() => _error = 'Longitude must be between -180 and 180.');
      return null;
    }
    setState(() => _error = null);
    return LaunchSite(
      name: name,
      latitude: lat,
      longitude: lon,
      altitudeMsl: alt,
    );
  }

  /// Saves the add/edit form. A rename deletes the original preset first
  /// (presets are keyed by name); the saved site ends up selected and the
  /// dialog returns to the list.
  Future<void> _saveForm() async {
    final site = _parseManual();
    if (site == null) return;
    final repo = ref.read(launchSiteProvider.notifier);
    final original = _editOriginal;
    if (original != null && original != site.name) {
      await repo.deletePreset(original);
    }
    await repo.savePreset(site);
    // Warm the tile cache around the site so the field map works offline.
    unawaited(precacheLaunchSites([site]));
    if (mounted) _closeForm();
  }

  /// Fills the coordinate fields from the rocket's current GPS position.
  void _fillFromFix() {
    final latest = ref.read(telemetryStoreProvider).latest;
    if (latest == null || !latest.gpsHasFix) {
      setState(() => _error = 'No GPS fix yet — wait for the rocket to fix.');
      return;
    }
    setState(() {
      _error = null;
      _lat.text = latest.latitude.toStringAsFixed(6);
      _lon.text = latest.longitude.toStringAsFixed(6);
      _alt.text = latest.gpsAltitude.toStringAsFixed(1);
    });
  }

  @override
  Widget build(BuildContext context) {
    final siteState =
        ref.watch(launchSiteProvider).value ?? const LaunchSiteState();

    return SizedBox(
      width: 440,
      child: SingleChildScrollView(
        child: _showForm ? _formView() : _listView(siteState),
      ),
    );
  }

  /// Saved list: Add on top, rows with edit + remove, tap selects.
  Widget _listView(LaunchSiteState siteState) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Text(
              'SAVED SITES',
              style: AppText.microLabel.copyWith(letterSpacing: 1.1),
            ),
            const Spacer(),
            FilledButton.icon(
              onPressed: _openAdd,
              icon: const Icon(Icons.add, size: 16),
              label: const Text('Add'),
            ),
          ],
        ),
        const SizedBox(height: 8),
        if (siteState.presets.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Text(
              'No saved sites yet — add the first one above.',
              style: TextStyle(
                fontSize: 12.5,
                color: AppColors.mutedForeground,
              ),
            ),
          )
        else
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 264),
            child: ListView.builder(
              shrinkWrap: true,
              itemCount: siteState.presets.length,
              itemBuilder: (context, i) =>
                  _presetRow(siteState, siteState.presets[i]),
            ),
          ),
      ],
    );
  }

  Widget _presetRow(LaunchSiteState siteState, LaunchSite preset) {
    final selected = siteState.selected?.name == preset.name;
    return Material(
      color: selected ? AppColors.pinkSoft : Colors.transparent,
      borderRadius: BorderRadius.circular(AppDimens.radiusSmall),
      child: InkWell(
        borderRadius: BorderRadius.circular(AppDimens.radiusSmall),
        mouseCursor: SystemMouseCursors.click,
        onTap: () async {
          await ref.read(launchSiteProvider.notifier).select(preset);
          if (!mounted) return;
          Navigator.of(context).pop();
        },
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          child: Row(
            children: [
              Icon(
                selected ? Icons.flag : Icons.flag_outlined,
                size: 16,
                color: selected
                    ? AppColors.pinkDeep
                    : AppColors.mutedForeground,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      preset.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    Text(
                      '${formatLatLon(preset.latitude, preset.longitude)} · ${preset.altitudeMsl.toStringAsFixed(0)} m MSL',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppText.mono.copyWith(
                        fontSize: 10.5,
                        color: AppColors.mutedForeground,
                      ),
                    ),
                  ],
                ),
              ),
              InkWell(
                onTap: () => _openEdit(preset),
                mouseCursor: SystemMouseCursors.click,
                borderRadius: BorderRadius.circular(4),
                child: Tooltip(
                  message: 'Edit site',
                  mouseCursor: SystemMouseCursors.click,
                  child: const Padding(
                    padding: EdgeInsets.all(4),
                    child: Icon(Icons.edit_outlined, size: 17),
                  ),
                ),
              ),
              InkWell(
                onTap: () => ref
                    .read(launchSiteProvider.notifier)
                    .deletePreset(preset.name),
                mouseCursor: SystemMouseCursors.click,
                borderRadius: BorderRadius.circular(4),
                child: Tooltip(
                  message: 'Remove site',
                  mouseCursor: SystemMouseCursors.click,
                  child: const Padding(
                    padding: EdgeInsets.all(4),
                    child: Icon(Icons.delete_outline, size: 17),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Add/edit form: name first, then either the rocket's current position
  /// or manually entered coordinates.
  Widget _formView() {
    final latest = ref.watch(telemetryStoreProvider).latest;
    final hasFix = latest?.gpsHasFix ?? false;
    final editing = _editOriginal != null;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          editing ? 'EDIT SITE' : 'ADD SITE',
          style: AppText.microLabel.copyWith(letterSpacing: 1.1),
        ),
        const SizedBox(height: 8),
        TextField(
          controller: _name,
          decoration: const InputDecoration(labelText: 'Name'),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Icon(
              hasFix ? Icons.my_location : Icons.location_searching,
              size: 16,
              color: hasFix ? AppColors.success : AppColors.mutedForeground,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                hasFix
                    ? '${formatLatLon(latest!.latitude, latest.longitude)} · ${latest.gpsAltitude.toStringAsFixed(0)} m MSL'
                    : 'Waiting for GPS fix…',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppText.mono.copyWith(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: AppColors.mutedForeground,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Tooltip(
          message: hasFix
              ? 'Fill the coordinates below from the rocket\u2019s GPS fix'
              : 'Needs a live GPS fix first',
          child: OutlinedButton.icon(
            onPressed: hasFix ? _fillFromFix : null,
            icon: const Icon(Icons.pin_drop_outlined, size: 16),
            label: const Text('Use current position'),
          ),
        ),
        const SizedBox(height: 8),
        Text(
          'OR ENTER MANUALLY',
          style: AppText.microLabel.copyWith(letterSpacing: 1.1),
        ),
        const SizedBox(height: 8),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: TextField(
                controller: _lat,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: 'Latitude (°)'),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: TextField(
                controller: _lon,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: 'Longitude (°)'),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: TextField(
                controller: _alt,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: 'Alt MSL (m)'),
              ),
            ),
          ],
        ),
        if (_error != null) ...[
          const SizedBox(height: 8),
          Text(
            _error!,
            style: TextStyle(color: AppColors.destructive, fontSize: 12),
          ),
        ],
        const SizedBox(height: 12),
        Row(
          children: [
            FilledButton.icon(
              onPressed: _saveForm,
              icon: const Icon(Icons.save_outlined, size: 16),
              label: const Text('Save'),
            ),
            const SizedBox(width: 8),
            OutlinedButton(onPressed: _closeForm, child: const Text('Cancel')),
          ],
        ),
      ],
    );
  }
}
