import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';

import '../../models/event.dart';
import '../../services/network_monitor.dart';
import '../../services/saved_events_store.dart';
import '../../services/schedule_repository.dart';
import 'attribute_pill.dart';
import 'event_detail_page.dart';
import 'save_event_action.dart';

class SchedulePage extends ConsumerWidget {
  const SchedulePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(scheduleRepositoryProvider);
    final connectivity = ref.watch(connectivityProvider).value;
    final isOffline = connectivity?.isOnline == false;

    final allEvents = [...state.events]
      ..sort((a, b) => a.startTime.compareTo(b.startTime));

    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Schedule'),
          actions: [
            IconButton(
              tooltip: 'Refresh',
              icon: state.isSyncing
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.refresh),
              onPressed: state.isSyncing
                  ? null
                  : () =>
                      ref.read(scheduleRepositoryProvider.notifier).refresh(),
            ),
          ],
          bottom: const TabBar(
            tabs: [
              Tab(text: 'All Sessions'),
              Tab(text: 'My Schedule'),
            ],
          ),
        ),
        body: Column(
          children: [
            if (isOffline) const _OfflineBanner(),
            if (state.errorMessage != null) _ErrorBanner(state.errorMessage!),
            Expanded(
              child: TabBarView(
                children: [
                  _EventList(events: allEvents, savedOnly: false),
                  _EventList(events: allEvents, savedOnly: true),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A continuous, chronological list of events with inline day headers.
/// When [savedOnly] is true it shows only events in "My Schedule".
class _EventList extends ConsumerWidget {
  final List<Event> events;
  final bool savedOnly;
  const _EventList({required this.events, required this.savedOnly});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final saved = savedOnly
        ? ref.watch(savedEventsProvider)
        : const <String, ReminderOption>{};
    final visible = savedOnly
        ? events.where((e) => saved.containsKey(e.id)).toList()
        : events;

    if (visible.isEmpty) {
      return savedOnly ? const _SavedEmptyState() : const _EmptyState();
    }

    // Flatten into header + event rows so a single ListView scrolls the lot.
    final items = <Object>[];
    String? lastDay;
    for (final e in visible) {
      if (e.dayKey != lastDay) {
        items.add(e.dayKey);
        lastDay = e.dayKey;
      }
      items.add(e);
    }

    // "All Sessions" opens positioned at the current point in the con; "My
    // Schedule" opens at the top. initialScrollIndex is applied once, when this
    // list is first built with data, so later refreshes don't yank the user.
    final initialIndex = savedOnly ? 0 : _nowAnchorIndex(items);

    return RefreshIndicator(
      onRefresh: () => ref.read(scheduleRepositoryProvider.notifier).refresh(),
      child: ScrollablePositionedList.builder(
        itemCount: items.length,
        initialScrollIndex: initialIndex,
        itemBuilder: (_, i) {
          final item = items[i];
          if (item is String) return _DayHeader(dayKey: item);
          return _EventTile(event: item as Event);
        },
      ),
    );
  }

  /// Index of the first still-current/upcoming session (its end is after now),
  /// preferring that day's header just above it for context. Falls back to the
  /// top when the whole schedule is in the past (or hasn't started).
  int _nowAnchorIndex(List<Object> items) {
    final now = DateTime.now();
    for (var i = 0; i < items.length; i++) {
      final item = items[i];
      if (item is Event && item.endTime.isAfter(now)) {
        if (i > 0 && items[i - 1] is String) return i - 1;
        return i;
      }
    }
    return 0;
  }
}

class _DayHeader extends StatelessWidget {
  final String dayKey;
  const _DayHeader({required this.dayKey});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final date = DateTime.parse(dayKey);
    return Container(
      width: double.infinity,
      color: scheme.surfaceContainerHighest,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Text(
        DateFormat('EEEE, MMMM d').format(date),
        style: Theme.of(context).textTheme.titleSmall?.copyWith(
              color: scheme.onSurfaceVariant,
              fontWeight: FontWeight.w700,
            ),
      ),
    );
  }
}

class _EventTile extends ConsumerWidget {
  final Event event;
  const _EventTile({required this.event});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isSaved =
        ref.watch(savedEventsProvider.select((s) => s.containsKey(event.id)));
    final timeFmt = DateFormat('h:mm a');
    final subtitleLine = [
      '${timeFmt.format(event.startTime)} – ${timeFmt.format(event.endTime)}',
      if (event.locationDisplayName != null) event.locationDisplayName!,
      if (event.track != null) event.track!,
    ].join(' · ');

    return ListTile(
      title: Text(event.title),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(subtitleLine),
          if (event.attributes.isNotEmpty)
            AttributePillRow(
              codes: event.attributes,
              padding: const EdgeInsets.only(top: 4),
            ),
        ],
      ),
      trailing: IconButton(
        icon: Icon(isSaved ? Icons.bookmark : Icons.bookmark_border),
        color: isSaved ? Theme.of(context).colorScheme.primary : null,
        tooltip: isSaved ? 'Remove from My Schedule' : 'Save to My Schedule',
        onPressed: () => toggleSaved(context, ref, event),
      ),
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => EventDetailPage(event: event)),
      ),
    );
  }
}

class _OfflineBanner extends StatelessWidget {
  const _OfflineBanner();
  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(children: const [
        Icon(Icons.wifi_off, size: 18),
        SizedBox(width: 8),
        Text('Offline — showing cached schedule'),
      ]),
    );
  }
}

class _ErrorBanner extends StatelessWidget {
  final String message;
  const _ErrorBanner(this.message);
  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      color: Theme.of(context).colorScheme.errorContainer,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Text(
        'Sync error: $message',
        style:
            TextStyle(color: Theme.of(context).colorScheme.onErrorContainer),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();
  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Padding(
        padding: EdgeInsets.all(32),
        child: Text(
          'No events yet. Pull to refresh once the schedule URL is set.',
          textAlign: TextAlign.center,
        ),
      ),
    );
  }
}

class _SavedEmptyState extends StatelessWidget {
  const _SavedEmptyState();
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.bookmark_border, size: 40, color: scheme.outline),
            const SizedBox(height: 12),
            Text(
              'No saved sessions yet.\nTap the bookmark on any session to build your schedule.',
              textAlign: TextAlign.center,
              style: TextStyle(color: scheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }
}
