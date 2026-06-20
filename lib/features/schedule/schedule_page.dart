import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../models/event.dart';
import '../../services/network_monitor.dart';
import '../../services/schedule_repository.dart';
import 'attribute_pill.dart';
import 'event_detail_page.dart';

class SchedulePage extends ConsumerStatefulWidget {
  const SchedulePage({super.key});

  @override
  ConsumerState<SchedulePage> createState() => _SchedulePageState();
}

class _SchedulePageState extends ConsumerState<SchedulePage> {
  String? _selectedDay;

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(scheduleRepositoryProvider);
    final connectivity = ref.watch(connectivityProvider).value;
    final isOffline = connectivity?.isOnline == false;

    final groupedByDay = <String, List<Event>>{};
    for (final e in state.events) {
      groupedByDay.putIfAbsent(e.dayKey, () => []).add(e);
    }
    final days = groupedByDay.keys.toList()..sort();
    final activeDay = _selectedDay != null && days.contains(_selectedDay)
        ? _selectedDay!
        : (days.isNotEmpty ? days.first : null);
    final eventsForDay = activeDay == null
        ? const <Event>[]
        : (groupedByDay[activeDay]!..sort((a, b) => a.startTime.compareTo(b.startTime)));

    return Scaffold(
      appBar: AppBar(
        title: const Text('Schedule'),
        actions: [
          IconButton(
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
      ),
      body: Column(
        children: [
          if (isOffline) const _OfflineBanner(),
          if (state.errorMessage != null) _ErrorBanner(state.errorMessage!),
          if (days.length > 1)
            _DayPicker(
              days: days,
              selected: activeDay!,
              onSelect: (d) => setState(() => _selectedDay = d),
            ),
          Expanded(
            child: eventsForDay.isEmpty
                ? const _EmptyState()
                : RefreshIndicator(
                    onRefresh: () =>
                        ref.read(scheduleRepositoryProvider.notifier).refresh(),
                    child: ListView.separated(
                      itemCount: eventsForDay.length,
                      separatorBuilder: (ctx, i) => const Divider(height: 1),
                      itemBuilder: (_, i) => _EventTile(event: eventsForDay[i]),
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}

class _DayPicker extends StatelessWidget {
  final List<String> days;
  final String selected;
  final ValueChanged<String> onSelect;
  const _DayPicker(
      {required this.days, required this.selected, required this.onSelect});

  @override
  Widget build(BuildContext context) {
    final fmt = DateFormat('EEE M/d');
    return SizedBox(
      height: 56,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        itemCount: days.length,
        separatorBuilder: (ctx, i) => const SizedBox(width: 8),
        itemBuilder: (_, i) {
          final d = days[i];
          final date = DateTime.parse(d);
          return ChoiceChip(
            label: Text(fmt.format(date)),
            selected: d == selected,
            onSelected: (_) => onSelect(d),
          );
        },
      ),
    );
  }
}

class _EventTile extends StatelessWidget {
  final Event event;
  const _EventTile({required this.event});

  @override
  Widget build(BuildContext context) {
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
      trailing: const Icon(Icons.chevron_right),
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
        style: TextStyle(
            color: Theme.of(context).colorScheme.onErrorContainer),
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
