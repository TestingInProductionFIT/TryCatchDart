import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../theme/app_colors.dart';
import '../components/app_card.dart';
import '../tiles/shared/map_tiles.dart';
import '../../state/launch_site_store.dart';

/// Settings screen: offline maps, appearance and about. Launch sites live
/// in the top-bar site dialog.
class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  bool _precaching = false;
  String? _precacheStatus;
  bool _checking = false;
  String? _coverageStatus;
  List<SiteCacheCoverage> _coverage = const [];

  Future<void> _checkCoverage(List<LaunchSite> presets) async {
    setState(() {
      _checking = true;
      _coverageStatus = null;
      _coverage = const [];
    });
    try {
      final coverage = await tileCacheCoverage(
        presets,
        onProgress: (done, total) {
          if (!mounted) return;
          setState(() =>
              _coverageStatus = 'Checking cached tiles… $done / $total');
        },
      );
      if (!mounted) return;
      setState(() {
        _coverage = coverage;
        var cached = 0;
        var total = 0;
        for (final c in coverage) {
          cached += c.cached;
          total += c.total;
        }
        _coverageStatus =
            'Cached $cached / $total tiles around ${coverage.length} site(s).';
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _coverageStatus = 'Check failed.');
    } finally {
      if (mounted) setState(() => _checking = false);
    }
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

    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 640),
        child: ListView(
          padding: const EdgeInsets.all(AppDimens.pagePadding),
          children: [
            AppCard(
              title: 'OFFLINE MAPS',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    'Street and satellite tiles are cached on disk as you '
                    'browse. Preload every saved launch site (about 1 km '
                    'around each, zooms 13–17) for offline field use. '
                    'Launch sites are managed from the flag button in the '
                    'top bar.',
                    style: TextStyle(
                        fontSize: 12.5, color: AppColors.mutedForeground),
                  ),
                  const SizedBox(height: 10),
                  // Wrap (not Row): the pair must survive narrow windows
                  // and wide fonts without overflowing.
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
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
                      OutlinedButton.icon(
                        onPressed: _checking ||
                                _precaching ||
                                siteState.presets.isEmpty
                            ? null
                            : () => _checkCoverage(siteState.presets),
                        icon: _checking
                            ? const SizedBox(
                                width: 14,
                                height: 14,
                                child: CircularProgressIndicator(
                                    strokeWidth: 2),
                              )
                            : const Icon(
                                Icons.fact_check_outlined,
                                size: 16),
                        label: Text(
                            _checking ? 'Checking…' : 'Check cached tiles'),
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
                  if (_coverageStatus != null) ...[
                    const SizedBox(height: 8),
                    Text(
                      _coverageStatus!,
                      style: AppText.mono.copyWith(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: AppColors.mutedForeground,
                      ),
                    ),
                  ],
                  for (final c in _coverage) ...[
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            c.site.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 12.5,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          '${c.cached} / ${c.total}',
                          style: AppText.mono.copyWith(
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                            color: c.cached >= c.total
                                ? AppColors.success
                                : AppColors.warning,
                            fontFeatures: const [
                              FontFeature.tabularFigures()
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 2),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(3),
                      child: LinearProgressIndicator(
                        value: c.total <= 0
                            ? 1
                            : (c.cached / c.total).clamp(0.0, 1.0),
                        minHeight: 5,
                        backgroundColor: AppColors.muted,
                        valueColor: AlwaysStoppedAnimation<Color>(
                          c.cached >= c.total
                              ? AppColors.success
                              : AppColors.warning,
                        ),
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
