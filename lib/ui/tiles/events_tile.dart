import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/flight_events.dart';
import '../../core/format.dart';
import '../../state/replay_controller.dart';
import '../../state/telemetry_store.dart';
import '../../theme/app_colors.dart';
import '../components/flight_event_style.dart';
import '../components/waiting_for_data.dart';

/// Flight event log: launch / apogee / parachute / touchdown milestones,
/// newest first.
///
/// Live, each row reads its age ticking up every second ("Launch — 12 s
/// ago"). During a replay the same rows read their flight time
/// ("Launch — at 1:23"); tapping one seeks the replay there, and events
/// still ahead of the playhead render dimmed.
class EventsTile extends ConsumerStatefulWidget {
  const EventsTile({super.key});

  @override
  ConsumerState<EventsTile> createState() => _EventsTileState();
}

class _EventsTileState extends ConsumerState<EventsTile> {
  Timer? _ticker;
  final ScrollController _scrollController = ScrollController();
  int _prevEventCount = 0;

  @override
  void initState() {
    super.initState();
    // Drives the live "N s ago" ages (packet times alone would freeze them
    // the moment telemetry stops); replay rows show fixed flight times.
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final store = ref.watch(telemetryStoreProvider);
    final replayActive = ref.watch(replayProvider.select((s) => s.isActive));
    final replaying = store.replaying && replayActive;

    if (!replaying && store.history.isEmpty) {
      return const Center(child: WaitingForData());
    }

    // Live scans the store ring; replay scans the whole pre-decoded flight
    // so milestones past the live ring cap still show.
    final events = replaying
        ? ref.watch(replayFlightEventsProvider)
        : detectFlightEvents(store.history.toList(growable: false));
    if (events.isEmpty) {
      return Center(
        child: Text(
          replaying ? 'No events in this recording' : 'No events yet',
          style: AppText.microLabel,
        ),
      );
    }

    // Live auto-scrolls to the bottom when new events arrive.
    if (!replaying && events.length > _prevEventCount) {
      _prevEventCount = events.length;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scrollController.hasClients) {
          _scrollController.animateTo(
            _scrollController.position.maxScrollExtent,
            duration: const Duration(milliseconds: 300),
            curve: Curves.easeOut,
          );
        }
      });
    } else if (replaying) {
      _prevEventCount = events.length;
    }

    final nowMs = DateTime.now().millisecondsSinceEpoch;
    return ListView.separated(
      controller: _scrollController,
      padding: const EdgeInsets.symmetric(vertical: 2),
      itemCount: events.length,
      separatorBuilder: (_, _) =>
          Divider(height: 1, thickness: 1, color: AppColors.border),
      // Oldest first: chronological order (oldest at top, newest at bottom).
      itemBuilder: (context, index) {
        final event = events[index];
        final time = replaying
            ? 'at ${formatMinSec(event.positionMs)}'
            : _formatAgo(nowMs - event.receivedAtMs);
        if (!replaying) {
          return _EventRow(event: event, time: time, replaying: false);
        }
        return _EventRow(event: event, time: time, replaying: true);
      },
    );
  }
}

/// One log row: marker dot + name + transition on the left, time on the
/// right. During a replay the whole row seeks to the event on tap.
class _EventRow extends ConsumerWidget {
  final FlightEvent event;
  final String time;
  final bool replaying;

  const _EventRow({
    required this.event,
    required this.time,
    required this.replaying,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final content = Padding(
      padding: const EdgeInsets.symmetric(vertical: 7),
      child: Row(
        children: [
          _TileDot(event: event, replaying: replaying),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  event.type.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppText.mono.copyWith(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w700,
                    color: AppColors.foreground,
                  ),
                ),
                Text(
                  event.type.transitionLabel.toUpperCase(),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppText.microLabel.copyWith(fontSize: 9),
                ),
              ],
            ),
          ),
          // Display-only clock — excluded from semantics so the ticking
          // live ages don't churn the Windows accessibility bridge. (The
          // replay row itself stays a button with the event name.)
          ExcludeSemantics(
            child: Text(
              time,
              maxLines: 1,
              style: AppText.mono.copyWith(
                fontSize: 11.5,
                fontWeight: FontWeight.w600,
                fontFeatures: const [FontFeature.tabularFigures()],
                color: AppColors.mutedForeground,
              ),
            ),
          ),
        ],
      ),
    );
    if (!replaying) return content;
    final isLoading = ref.watch(replayProvider.select((s) => s.isLoading));
    return Tooltip(
      message:
          '${event.type.label} at ${formatMinSec(event.positionMs)} — tap to seek',
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: isLoading
            ? null
            : () => ref.read(replayProvider.notifier).seek(event.positionMs),
        child: MouseRegion(cursor: SystemMouseCursors.click, child: content),
      ),
    );
  }
}

/// Marker dot for a log row. Static live; during a replay a leaf consumer
/// on the playhead dims events still ahead, so the row (and its tooltip
/// graft) never rebuilds at the ticker rate.
class _TileDot extends ConsumerWidget {
  final FlightEvent event;
  final bool replaying;

  const _TileDot({required this.event, required this.replaying});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!replaying) return FlightEventDot(type: event.type);
    final positionMs = ref.watch(replayProvider.select((s) => s.positionMs));
    return FlightEventDot(
      type: event.type,
      dimmed: positionMs < event.positionMs,
    );
  }
}

/// Milliseconds → `5 s ago` / `3 m 04 s ago` (clamped at zero).
String _formatAgo(int ms) {
  final s = (ms.clamp(0, 1 << 62)) ~/ 1000;
  if (s < 60) return '$s s ago';
  return '${s ~/ 60} m ${(s % 60).toString().padLeft(2, '0')} s ago';
}
