import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/channel_health.dart';
import './telemetry_provider.dart';

/// App-lifetime channel-health history, fed from the worker's link-stats
/// stream.
///
/// The dashboard tile, the Channel-health screen and the top-bar widgets
/// previously each owned a private [ChannelHealthTracker] in their `State`,
/// so any remount discarded every accumulated sample and the chart visibly
/// reset. The worst trigger was the dashboard edit-mode toggle: entering or
/// leaving edit mode swaps `AbsorbPointer`/`GestureDetector` wrappers around
/// every tile, which unmounts the tile `State`. Other tiles re-render
/// immediately from global providers (`telemetryStoreProvider`, ...), but
/// link-stats snapshots are delivered once through
/// [linkStatsStreamProvider] — lose the `State`, lose the history.
///
/// One shared tracker survives widget rebuilds, remounts and screen
/// switches. The provider's state is a version counter bumped on every
/// snapshot so consumers rebuild; the tracker itself is read off the
/// notifier.
class ChannelHealthNotifier extends Notifier<int> {
  final ChannelHealthTracker tracker = ChannelHealthTracker();

  @override
  int build() {
    ref.listen(linkStatsStreamProvider, (_, next) {
      next.whenData((stats) {
        tracker.addSnapshot(stats);
        state++;
      });
    });
    return 0;
  }
}

final channelHealthProvider =
    NotifierProvider<ChannelHealthNotifier, int>(ChannelHealthNotifier.new);
