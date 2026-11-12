import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:intl/intl.dart';
import 'package:timezone/data/latest_all.dart' as tz_data;
import 'package:timezone/timezone.dart' as tz;

import '../models/event.dart';
import 'saved_events_store.dart';
import 'stable_hash.dart';

/// Schedules on-device reminder notifications for saved events.
///
/// This is local (device alarm) notification, not server push. Event times in
/// the schedule are naive wall-clock `DateTime`s meaning venue time, so
/// reminders are scheduled in [venueTimeZone] — not the device's zone, which
/// would fire an hour off for anyone who saved a session before travelling.
class NotificationService {
  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();
  Future<void>? _initializing;

  /// The Alabama 4-H Center's zone; every time in the schedule is in it.
  static const venueTimeZone = 'America/Chicago';

  static const _channelId = 'event_reminders';
  static const _channelName = 'Event reminders';
  static const _channelDescription =
      'Reminders for sessions you saved to My Schedule';

  /// Safe to call from anywhere, any number of times: concurrent callers
  /// share one initialization, and a failed attempt is retried on the next
  /// call rather than leaving the service half-configured.
  Future<void> init() => _initializing ??= () async {
    try {
      await _init();
    } catch (_) {
      _initializing = null;
      rethrow;
    }
  }();

  Future<void> _init() async {
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
  }

  /// Requests notification permission. Call this contextually — when the user
  /// first opts into a reminder — so the prompt isn't the first thing they see
  /// on launch.
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
      return await android.requestNotificationsPermission() ?? false;
    }
    return true;
  }

  // Notification IDs are ints; derive a stable positive one from the event ID.
  int _idFor(String eventId) => fnv1a32(eventId) & 0x7fffffff;

  static tz.Location _venueLocation() {
    try {
      return tz.getLocation(venueTimeZone);
    } on tz.LocationNotFoundException {
      // The zone database isn't loaded yet (init() hasn't run).
      tz_data.initializeTimeZones();
      return tz.getLocation(venueTimeZone);
    }
  }

  /// The instant [reminder] should fire for [event], or null when there is
  /// nothing to schedule: no reminder was chosen, or the moment has already
  /// passed. [event]'s start is read as venue time; [now] is any instant.
  static tz.TZDateTime? fireTime(Event event, Reminder reminder, DateTime now) {
    final lead = reminder.leadMinutes;
    if (lead == null) return null;
    final s = event.startTime;
    final fireAt = tz.TZDateTime(
      _venueLocation(),
      s.year,
      s.month,
      s.day,
      s.hour,
      s.minute,
    ).subtract(Duration(minutes: lead));
    return fireAt.isAfter(now) ? fireAt : null;
  }

  /// Schedules (or reschedules) the reminder for [event]. A none reminder
  /// simply cancels any existing one. Fire-times in the past are skipped.
  Future<void> schedule(Event event, Reminder reminder) async {
    await init();
    await cancel(event.id);
    final fireAt = fireTime(event, reminder, DateTime.now());
    if (fireAt == null) return;
    final lead = reminder.leadMinutes!;

    final loc = event.locationDisplayName;
    final timeStr = DateFormat('h:mm a').format(event.startTime);
    final body = lead == 0
        ? (loc != null ? 'Starting now · $loc' : 'Starting now')
        : (loc != null ? 'Starts at $timeStr · $loc' : 'Starts at $timeStr');

    await _plugin.zonedSchedule(
      id: _idFor(event.id),
      title: event.title,
      body: body,
      scheduledDate: fireAt,
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
      // Inexact: Play Store restricts USE_EXACT_ALARM to calendar/alarm-clock
      // apps. A few minutes of slack on a reminder is fine for con events.
      androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
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
