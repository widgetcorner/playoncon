import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/event.dart';
import '../../services/notification_service.dart';
import '../../services/saved_events_store.dart';

/// Toggles an event's saved state. When *saving* (not un-saving), prompts for a
/// reminder choice via a modal dialog and schedules it. Dismissing the dialog
/// cancels the save entirely.
Future<void> toggleSaved(
  BuildContext context,
  WidgetRef ref,
  Event event,
) async {
  final store = ref.read(savedEventsProvider.notifier);

  if (store.isSaved(event.id)) {
    store.remove(event.id);
    await ref.read(notificationServiceProvider).cancel(event.id);
    return;
  }

  final choice = await _showReminderDialog(context, ref);
  if (choice == null) return; // dismissed → don't save

  store.save(event.id, choice);
  final notifications = ref.read(notificationServiceProvider);
  if (!choice.isNone) {
    await notifications.requestPermission();
  }
  await notifications.schedule(event, choice);

  if (context.mounted && !choice.isNone) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Saved with a reminder')));
  }
}

String _minutesLabel(int minutes) =>
    '$minutes ${minutes == 1 ? 'minute' : 'minutes'} before';

Future<Reminder?> _showReminderDialog(BuildContext context, WidgetRef ref) {
  final lastCustom = ref.read(lastCustomReminderProvider);
  return showDialog<Reminder>(
    context: context,
    builder: (ctx) => SimpleDialog(
      title: const Text('Add a reminder?'),
      children: [
        // The last custom time the user picked (persisted) leads the list.
        if (lastCustom != null)
          _ReminderRow(
            icon: Icons.alarm,
            label: _minutesLabel(lastCustom),
            onTap: () => Navigator.pop(ctx, Reminder.minutes(lastCustom)),
          ),
        _ReminderRow(
          icon: Icons.tune,
          label: 'Custom…',
          onTap: () async {
            final minutes = await _showMinutePicker(ctx, lastCustom ?? 15);
            if (minutes == null) return; // back out, keep dialog open
            ref.read(lastCustomReminderProvider.notifier).set(minutes);
            if (ctx.mounted) Navigator.pop(ctx, Reminder.minutes(minutes));
          },
        ),
        _ReminderRow(
          icon: Icons.play_circle_outline,
          label: 'At start time',
          onTap: () => Navigator.pop(ctx, const Reminder.atStart()),
        ),
        _ReminderRow(
          icon: Icons.notifications_off_outlined,
          label: 'No reminder',
          onTap: () => Navigator.pop(ctx, const Reminder.none()),
        ),
      ],
    ),
  );
}

/// A simple 1–120 minute wheel selector for a custom reminder lead time.
Future<int?> _showMinutePicker(BuildContext context, int initial) {
  return showModalBottomSheet<int>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (ctx) => _MinutePicker(initial: initial),
  );
}

class _MinutePicker extends StatefulWidget {
  final int initial;
  const _MinutePicker({required this.initial});

  @override
  State<_MinutePicker> createState() => _MinutePickerState();
}

class _MinutePickerState extends State<_MinutePicker> {
  late int _selected;
  late final FixedExtentScrollController _controller;

  @override
  void initState() {
    super.initState();
    _selected = widget.initial.clamp(1, 120);
    _controller = FixedExtentScrollController(initialItem: _selected - 1);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Keep the wheel and its selection mounted as the window changes. The
    // surrounding scroll view keeps the confirmation reachable in short views.
    final itemExtent = MediaQuery.textScalerOf(context).scale(22) + 14;
    return SafeArea(
      top: false,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 480),
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'Remind me before the event',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 4),
              Text(
                _minutesLabel(_selected),
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: Theme.of(context).colorScheme.primary,
                  fontWeight: FontWeight.w600,
                ),
              ),
              SizedBox(
                height: itemExtent * 5,
                child: CupertinoPicker(
                  scrollController: _controller,
                  itemExtent: itemExtent,
                  onSelectedItemChanged: (i) =>
                      setState(() => _selected = i + 1),
                  children: [
                    for (var m = 1; m <= 120; m++) Center(child: Text('$m')),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: () => Navigator.pop(context, _selected),
                  child: const Text(
                    'Set reminder',
                    textAlign: TextAlign.center,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ReminderRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  const _ReminderRow({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return SimpleDialogOption(
      onPressed: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(
          children: [
            Icon(icon, size: 20, color: Theme.of(context).colorScheme.primary),
            const SizedBox(width: 16),
            Expanded(
              child: Text(label, style: Theme.of(context).textTheme.bodyLarge),
            ),
          ],
        ),
      ),
    );
  }
}
