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
    final isSaved =
        ref.watch(savedEventsProvider.select((s) => s.containsKey(event.id)));
    return Scaffold(
      appBar: AppBar(
        title: Text(event.title),
        actions: [
          IconButton(
            icon: Icon(isSaved ? Icons.bookmark : Icons.bookmark_border),
            tooltip: isSaved ? 'Remove from My Schedule' : 'Save to My Schedule',
            onPressed: () => toggleSaved(context, ref, event),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(
            '${dateFmt.format(event.startTime)} · ${timeFmt.format(event.startTime)} – ${timeFmt.format(event.endTime)}',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 12),
          if (event.locationDisplayName != null)
            _DetailRow(icon: Icons.place, label: event.locationDisplayName!),
          if (event.locationKey != null) ...[
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerLeft,
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
            _DetailRow(icon: Icons.label_outline, label: event.track!),
          if (event.presenter != null)
            _DetailRow(icon: Icons.person_outline, label: event.presenter!),
          if (event.attributes.isNotEmpty) ...[
            const SizedBox(height: 12),
            AttributePillRow(codes: event.attributes, dense: false),
          ],
          if (event.details != null) ...[
            const SizedBox(height: 16),
            Text(event.details!),
          ],
        ],
      ),
    );
  }
}

class _DetailRow extends StatelessWidget {
  final IconData icon;
  final String label;
  const _DetailRow({required this.icon, required this.label});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(children: [
        Icon(icon, size: 18, color: Theme.of(context).colorScheme.outline),
        const SizedBox(width: 8),
        Expanded(child: Text(label)),
      ]),
    );
  }
}
