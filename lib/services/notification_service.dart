import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:intl/intl.dart';
import 'package:timezone/data/latest_all.dart' as tz_data;
import 'package:timezone/timezone.dart' as tz;

import '../models/event.dart';
import 'saved_events_store.dart';

/// Schedules on-device reminder notifications for saved events.
///
/// This is local (device alarm) notification — distinct from the OneSignal
/// push planned for M2, which is for broadcast announcements. Event times in
/// the schedule are naive wall-clock `DateTime`s, so we schedule against the
/// device's local timezone to match what the schedule shows.
class NotificationService {
  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();
  bool _initialized = false;

  static const _channelId = 'event_reminders';
  static const _channelName = 'Event reminders';
  static const _channelDescription =
      'Reminders for sessions you saved to My Schedule';

  Future<void> init() async {
    if (_initialized) return;
    tz_data.initializeTimeZones();
    try {
      final info = await FlutterTimezone.getLocalTimezone();
      tz.setLocalLocation(tz.getLocation(info.identifier));
    } catch (_) {
      // Detection failed → tz.local stays UTC; reminders still fire, just
      // computed against UTC offset. Best-effort.
    }
    const android = AndroidInitializationSettings('@mipmap/ic_launcher');
    const darwin = DarwinInitializationSettings(
      requestAlertPermission: false,
      requestBadgePermission: false,
      requestSoundPermission: false,
    );
    await _plugin.initialize(
      settings: const InitializationSettings(android: android, iOS: darwin),
    );
    await _plugin
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>()
        ?.createNotificationChannel(const AndroidNotificationChannel(
          _channelId,
          _channelName,
          description: _channelDescription,
          importance: Importance.high,
        ));
    _initialized = true;
  }

  /// Requests notification permission (and, on Android, exact-alarm access).
  /// Call this contextually — when the user first opts into a reminder — so the
  /// prompt isn't the first thing they see on launch.
  Future<bool> requestPermission() async {
    await init();
    final ios = _plugin.resolvePlatformSpecificImplementation<
        IOSFlutterLocalNotificationsPlugin>();
    if (ios != null) {
      return await ios.requestPermissions(
            alert: true,
            badge: true,
            sound: true,
          ) ??
          false;
    }
    final android = _plugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    if (android != null) {
      final granted = await android.requestNotificationsPermission() ?? false;
      await android.requestExactAlarmsPermission();
      return granted;
    }
    return true;
  }

  // Notification IDs are ints; derive a stable positive one from the event ID.
  int _idFor(String eventId) => eventId.hashCode & 0x7fffffff;

  /// Schedules (or reschedules) the reminder for [event]. [ReminderOption.none]
  /// simply cancels any existing reminder. Fire-times in the past are skipped.
  Future<void> schedule(Event event, ReminderOption option) async {
    await init();
    await cancel(event.id);
    final lead = option.leadTime;
    if (lead == null) return;
    final fireAt = event.startTime.subtract(lead);
    if (!fireAt.isAfter(DateTime.now())) return;

    final loc = event.locationDisplayName;
    final timeStr = DateFormat('h:mm a').format(event.startTime);
    final body = option == ReminderOption.atStart
        ? (loc != null ? 'Starting now · $loc' : 'Starting now')
        : (loc != null ? 'Starts at $timeStr · $loc' : 'Starts at $timeStr');

    await _plugin.zonedSchedule(
      id: _idFor(event.id),
      title: event.title,
      body: body,
      scheduledDate: tz.TZDateTime.from(fireAt, tz.local),
      notificationDetails: const NotificationDetails(
        android: AndroidNotificationDetails(
          _channelId,
          _channelName,
          channelDescription: _channelDescription,
          importance: Importance.high,
          priority: Priority.high,
        ),
        iOS: DarwinNotificationDetails(),
      ),
      androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
      payload: event.id,
    );
  }

  Future<void> cancel(String eventId) async {
    await init();
    await _plugin.cancel(id: _idFor(eventId));
  }
}

final notificationServiceProvider =
    Provider<NotificationService>((_) => NotificationService());
