import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../app_navigation.dart';
import '../../models/event.dart';
import '../../services/saved_events_store.dart';
import 'attribute_pill.dart';
import 'save_event_action.dart';

class EventDetailPage extends ConsumerWidget {
  final Event event;
  const EventDetailPage({super.key, required this.event});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final dateFmt = DateFormat('EEEE, MMM d');
    final timeFmt = DateFormat('h:mm a');
    final isSaved = ref.watch(
      savedEventsProvider.select((s) => s.containsKey(event.id)),
    );
    return Scaffold(
      appBar: AppBar(
        title: Text(event.title, maxLines: 1, overflow: TextOverflow.ellipsis),
        actions: [
          IconButton(
            isSelected: isSaved,
            icon: const Icon(Icons.bookmark_border),
            selectedIcon: const Icon(Icons.bookmark),
            tooltip: isSaved
                ? 'Remove from My Schedule: ${event.title}'
                : 'Save to My Schedule: ${event.title}',
            onPressed: () => toggleSaved(context, ref, event),
          ),
        ],
      ),
      body: SafeArea(
        top: false,
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 720),
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Semantics(
                  header: true,
                  child: Text(
                    event.title,
                    style: Theme.of(context).textTheme.headlineSmall,
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  '${dateFmt.format(event.startTime)} · ${timeFmt.format(event.startTime)} – ${timeFmt.format(event.endTime)}',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 12),
                if (event.locationDisplayName != null)
                  _DetailRow(
                    icon: Icons.place,
                    label: event.locationDisplayName!,
                    semanticLabel: 'Location: ${event.locationDisplayName!}',
                  ),
                if (event.locationKey != null) ...[
                  const SizedBox(height: 8),
                  Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: OutlinedButton.icon(
                      icon: const Icon(Icons.map_outlined),
                      label: const Text('Show on map'),
                      onPressed: () {
                        ref.showOnMap(event.locationKey!);
                        Navigator.of(context).maybePop();
                      },
                    ),
                  ),
                ],
                if (event.track != null)
                  _DetailRow(
                    icon: Icons.label_outline,
                    label: event.track!,
                    semanticLabel: 'Track: ${event.track!}',
                  ),
                if (event.presenter != null)
                  _DetailRow(
                    icon: Icons.person_outline,
                    label: event.presenter!,
                    semanticLabel: 'Presenter: ${event.presenter!}',
                  ),
                if (event.attributes.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  AttributePillRow(codes: event.attributes, dense: false),
                ],
                if (event.subSchedule.isNotEmpty) ...[
                  const SizedBox(height: 16),
                  Semantics(
                    header: true,
                    child: Text(
                      'Schedule',
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                  ),
                  const SizedBox(height: 4),
                  for (final item in event.subSchedule)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 2),
                      child: Text(
                        '• ${item.label} — ${timeFmt.format(item.time)}',
                      ),
                    ),
                ],
                if (event.details != null) ...[
                  const SizedBox(height: 16),
                  Text(event.details!),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _DetailRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final String semanticLabel;
  const _DetailRow({
    required this.icon,
    required this.label,
    required this.semanticLabel,
  });

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: semanticLabel,
      excludeSemantics: true,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          children: [
            Icon(icon, size: 18, color: Theme.of(context).colorScheme.outline),
            const SizedBox(width: 8),
            Expanded(child: Text(label)),
          ],
        ),
      ),
    );
  }
}
