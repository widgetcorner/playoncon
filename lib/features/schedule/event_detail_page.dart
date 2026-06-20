import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../models/event.dart';
import 'attribute_pill.dart';

class EventDetailPage extends StatelessWidget {
  final Event event;
  const EventDetailPage({super.key, required this.event});

  @override
  Widget build(BuildContext context) {
    final dateFmt = DateFormat('EEEE, MMM d');
    final timeFmt = DateFormat('h:mm a');
    return Scaffold(
      appBar: AppBar(title: Text(event.title)),
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
