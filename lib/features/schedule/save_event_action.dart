import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/event.dart';
import '../../services/notification_service.dart';
import '../../services/saved_events_store.dart';

/// Toggles an event's saved state. When *saving* (not un-saving), prompts for a
/// reminder choice via a modal dialog and schedules it. Dismissing the dialog
/// cancels the save entirely.
Future<void> toggleSaved(
    BuildContext context, WidgetRef ref, Event event) async {
  final store = ref.read(savedEventsProvider.notifier);

  if (store.isSaved(event.id)) {
    store.remove(event.id);
    await ref.read(notificationServiceProvider).cancel(event.id);
    return;
  }

  final choice = await _showReminderDialog(context);
  if (choice == null) return; // dismissed → don't save

  store.save(event.id, choice);
  final notifications = ref.read(notificationServiceProvider);
  if (choice != ReminderOption.none) {
    await notifications.requestPermission();
  }
  await notifications.schedule(event, choice);

  if (context.mounted && choice != ReminderOption.none) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Saved with a reminder')),
    );
  }
}

Future<ReminderOption?> _showReminderDialog(BuildContext context) {
  return showDialog<ReminderOption>(
    context: context,
    builder: (ctx) => SimpleDialog(
      title: const Text('Add a reminder?'),
      children: [
        _ReminderChoice(
          icon: Icons.alarm,
          label: '15 minutes before',
          value: ReminderOption.fifteenMinutesBefore,
        ),
        _ReminderChoice(
          icon: Icons.play_circle_outline,
          label: 'At start time',
          value: ReminderOption.atStart,
        ),
        _ReminderChoice(
          icon: Icons.notifications_off_outlined,
          label: 'No reminder',
          value: ReminderOption.none,
        ),
      ],
    ),
  );
}

class _ReminderChoice extends StatelessWidget {
  final IconData icon;
  final String label;
  final ReminderOption value;
  const _ReminderChoice({
    required this.icon,
    required this.label,
    required this.value,
  });

  @override
  Widget build(BuildContext context) {
    return SimpleDialogOption(
      onPressed: () => Navigator.pop(context, value),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(children: [
          Icon(icon, size: 20, color: Theme.of(context).colorScheme.primary),
          const SizedBox(width: 16),
          Text(label, style: Theme.of(context).textTheme.bodyLarge),
        ]),
      ),
    );
  }
}
