import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../theme/app_colors.dart';
import '../theme/widgets/app_card.dart';
import '../workspaces/widgets/map_tiles.dart';
import 'launch_site_store.dart';

/// Settings screen: launch site configuration with savable presets.
class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  final _name = TextEditingController();
  final _lat = TextEditingController();
  final _lon = TextEditingController();
  final _alt = TextEditingController();
  String? _error;
  bool _syncedFromSelection = false;
  bool _precaching = false;
  String? _precacheStatus;

  @override
  void dispose() {
    _name.dispose();
    _lat.dispose();
    _lon.dispose();
    _alt.dispose();
    super.dispose();
  }

  /// Prefills the form from the currently selected site (once loaded).
  void _syncFromSelection(LaunchSite? site) {
    if (_syncedFromSelection) return;
    _syncedFromSelection = true;
    if (site != null) _fill(site);
  }

  void _fill(LaunchSite site) {
    _name.text = site.name;
    _lat.text = site.latitude.toStringAsFixed(6);
    _lon.text = site.longitude.toStringAsFixed(6);
    _alt.text = site.altitudeMsl.toStringAsFixed(1);
  }

  void _clearForm() {
    _name.clear();
    _lat.clear();
    _lon.clear();
    _alt.clear();
    _error = null;
  }

  LaunchSite? _parseForm() {
    final name = _name.text.trim();
    final lat = double.tryParse(_lat.text.trim().replaceAll(',', '.'));
    final lon = double.tryParse(_lon.text.trim().replaceAll(',', '.'));
    final alt = double.tryParse(_alt.text.trim().replaceAll(',', '.')) ?? 0;

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
    return LaunchSite(name: name, latitude: lat, longitude: lon, altitudeMsl: alt);
  }

  Future<void> _precacheAll(List<LaunchSite> presets) async {
    setState(() {
      _precaching = true;
      _precacheStatus = null;
    });
    try {
      final (:fetched, :total) = await precacheLaunchSites(
        presets,
        onProgress: (done, total) {
          if (!mounted) return;
          setState(() =>
              _precacheStatus = 'Downloading tiles… $done / $total');
        },
      );
      if (!mounted) return;
      setState(() => _precacheStatus =
          'Done — $fetched new tiles cached ($total checked).');
    } catch (_) {
      if (!mounted) return;
      setState(
          () => _precacheStatus = 'Preload failed — check the connection.');
    } finally {
      if (mounted) setState(() => _precaching = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(launchSiteProvider);
    final siteState = state.value ?? const LaunchSiteState();
    _syncFromSelection(siteState.selected);

    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 640),
        child: ListView(
          padding: const EdgeInsets.all(AppDimens.pagePadding),
          children: [
            AppCard(
              title: 'LAUNCH SITE',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // Preset picker.
                  Row(
                    children: [
                      Expanded(
                        child: DropdownButtonFormField<String>(
                          initialValue: siteState.selected?.name,
                          hint: const Text('Load a preset'),
                          isDense: true,
                          borderRadius:
                              BorderRadius.circular(AppDimens.radiusSmall),
                          items: [
                            for (final preset in siteState.presets)
                              DropdownMenuItem(
                                value: preset.name,
                                child: Text(preset.name),
                              ),
                          ],
                          onChanged: (name) {
                            final preset = siteState.presets
                                .where((p) => p.name == name)
                                .firstOrNull;
                            if (preset != null) {
                              _fill(preset);
                              ref
                                  .read(launchSiteProvider.notifier)
                                  .select(preset);
                            }
                          },
                        ),
                      ),
                      const SizedBox(width: 8),
                      IconButton(
                        tooltip: 'Delete selected preset',
                        onPressed: siteState.selected == null
                            ? null
                            : () => ref
                                .read(launchSiteProvider.notifier)
                                .deletePreset(siteState.selected!.name),
                        icon: const Icon(Icons.delete_outline, size: 18),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _name,
                    decoration: const InputDecoration(labelText: 'Name'),
                  ),
                  const SizedBox(height: 10),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _lat,
                          keyboardType: TextInputType.number,
                          decoration:
                              const InputDecoration(labelText: 'Latitude (°)'),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: TextField(
                          controller: _lon,
                          keyboardType: TextInputType.number,
                          decoration:
                              const InputDecoration(labelText: 'Longitude (°)'),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: TextField(
                          controller: _alt,
                          keyboardType: TextInputType.number,
                          decoration: const InputDecoration(
                              labelText: 'Altitude MSL (m)'),
                        ),
                      ),
                    ],
                  ),
                  if (_error != null) ...[
                    const SizedBox(height: 8),
                    Text(
                _error!,
                style: TextStyle(
                    color: AppColors.destructive, fontSize: 12),
                    ),
                  ],
                  const SizedBox(height: 14),
                      Row(
                    children: [
                      FilledButton.icon(
                        onPressed: () async {
                          final site = _parseForm();
                          if (site == null) return;
                          await ref
                              .read(launchSiteProvider.notifier)
                              .savePreset(site);
                          // Warm the tile cache around the new site so the
                          // field map works offline.
                          unawaited(precacheLaunchSites([site]));
                        },
                        icon: const Icon(Icons.save_outlined, size: 16),
                        label: const Text('Save as preset'),
                      ),
                      const SizedBox(width: 8),
                      OutlinedButton(
                        onPressed: () {
                          final site = _parseForm();
                          if (site == null) return;
                          ref
                              .read(launchSiteProvider.notifier)
                              .select(site);
                        },
                        child: const Text('Use without saving'),
                      ),
                      const Spacer(),
                      OutlinedButton(
                        onPressed: () {
                          _clearForm();
                          ref.read(launchSiteProvider.notifier).select(null);
                        },
                        child: const Text('Clear'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: AppDimens.gap),
            AppCard(
              title: 'OFFLINE MAPS',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    'Street and satellite tiles are cached on disk as you '
                    'browse. Preload every saved launch site (about 1 km '
                    'around each, zooms 13–17) for offline field use.',
                    style: TextStyle(
                        fontSize: 12.5, color: AppColors.mutedForeground),
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      FilledButton.icon(
                        onPressed: _precaching || siteState.presets.isEmpty
                            ? null
                            : () => _precacheAll(siteState.presets),
                        icon: _precaching
                            ? const SizedBox(
                                width: 14,
                                height: 14,
                                child: CircularProgressIndicator(
                                    strokeWidth: 2),
                              )
                            : const Icon(Icons.download_outlined, size: 16),
                        label: Text(_precaching
                            ? 'Preloading…'
                            : 'Preload tiles around saved sites'),
                      ),
                    ],
                  ),
                  if (_precacheStatus != null) ...[
                    const SizedBox(height: 8),
                    Text(
                      _precacheStatus!,
                      style: AppText.mono.copyWith(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: AppColors.mutedForeground,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(height: AppDimens.gap),
            AppCard(
              title: 'APPEARANCE',
              child: ValueListenableBuilder<bool>(
                valueListenable: AppThemeMode.instance,
                builder: (_, isDark, _) => Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // Own Material: a ListTile paints its splash on the
                    // nearest Material ancestor, and AppCard's decorated
                    // container would swallow it (framework assert).
                    Material(
                      color: Colors.transparent,
                      child: SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        title: const Text('Dark mode'),
                        subtitle: Text(
                          'Charts, panels and chrome follow. Map tiles stay light.',
                          style: TextStyle(
                              fontSize: 12.5,
                              color: AppColors.mutedForeground),
                        ),
                        value: isDark,
                        onChanged: (v) =>
                            AppThemeMode.instance.setDark(v),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: AppDimens.gap),
            AppCard(
              title: 'ABOUT',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    '{TryCatch} ground station',
                    style: TextStyle(fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Testing in Production — model rocket telemetry, '
                    'replay and control.',
                    style: TextStyle(
                        fontSize: 12.5, color: AppColors.mutedForeground),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
