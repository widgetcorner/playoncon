import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
    animationStyle: MediaQuery.disableAnimationsOf(context)
        ? AnimationStyle.noAnimation
        : null,
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
        Semantics(
          container: true,
          button: true,
          child: SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx),
            child: const Padding(
              padding: EdgeInsets.symmetric(vertical: 8),
              child: Text('Cancel'),
            ),
          ),
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
    sheetAnimationStyle: MediaQuery.disableAnimationsOf(context)
        ? AnimationStyle.noAnimation
        : null,
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
  late final TextEditingController _minutesController;
  String? _inputError;

  @override
  void initState() {
    super.initState();
    _selected = widget.initial.clamp(1, 120);
    _controller = FixedExtentScrollController(initialItem: _selected - 1);
    _minutesController = TextEditingController(text: '$_selected');
  }

  @override
  void dispose() {
    _controller.dispose();
    _minutesController.dispose();
    super.dispose();
  }

  void _enterMinutes(String value) {
    final minutes = int.tryParse(value);
    if (minutes == null || minutes < 1 || minutes > 120) {
      setState(() => _inputError = 'Enter 1 to 120 minutes');
      return;
    }
    setState(() {
      _selected = minutes;
      _inputError = null;
    });
    _controller.jumpToItem(minutes - 1);
  }

  void _pickMinutes(int index) {
    final minutes = index + 1;
    setState(() {
      _selected = minutes;
      _inputError = null;
    });
    if (_minutesController.text != '$minutes') {
      _minutesController.text = '$minutes';
    }
  }

  @override
  Widget build(BuildContext context) {
    // Keep the wheel and its selection mounted as the window changes. The
    // surrounding scroll view keeps the confirmation reachable in short views.
    final itemExtent = MediaQuery.textScalerOf(context).scale(22) + 14;
    final scheme = Theme.of(context).colorScheme;
    return SafeArea(
      top: false,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 480),
        child: SingleChildScrollView(
          padding: EdgeInsets.fromLTRB(
            16,
            16,
            16,
            16 + MediaQuery.viewInsetsOf(context).bottom,
          ),
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
              const SizedBox(height: 12),
              TextField(
                controller: _minutesController,
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                decoration: InputDecoration(
                  labelText: 'Minutes before the event',
                  helperText: 'Enter 1 to 120, or use the picker below',
                  helperMaxLines: 3,
                  errorText: _inputError,
                  errorMaxLines: 2,
                ),
                onChanged: _enterMinutes,
              ),
              const SizedBox(height: 12),
              SizedBox(
                height: itemExtent * 5,
                child: CupertinoPicker(
                  backgroundColor: scheme.surface,
                  scrollController: _controller,
                  itemExtent: itemExtent,
                  onSelectedItemChanged: _pickMinutes,
                  children: [
                    for (var m = 1; m <= 120; m++)
                      Center(
                        child: Text(
                          '$m',
                          semanticsLabel: _minutesLabel(m),
                          style: TextStyle(color: scheme.onSurface),
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: _inputError == null
                      ? () => Navigator.pop(context, _selected)
                      : null,
                  child: const Text(
                    'Set reminder',
                    textAlign: TextAlign.center,
                  ),
                ),
              ),
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Cancel'),
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
    return Semantics(
      container: true,
      button: true,
      child: SimpleDialogOption(
        onPressed: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Row(
            children: [
              Icon(
                icon,
                size: 20,
                color: Theme.of(context).colorScheme.primary,
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Text(
                  label,
                  style: Theme.of(context).textTheme.bodyLarge,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
