import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:playoncon/models/event.dart';
import 'package:playoncon/services/atomic_file.dart';
import 'package:playoncon/services/event_descriptions.dart';
import 'package:playoncon/services/map_georeference.dart';
import 'package:playoncon/services/notification_service.dart';
import 'package:playoncon/services/saved_events_store.dart';
import 'package:playoncon/services/schedule_repository.dart';
import 'package:playoncon/services/server_clock.dart';
import 'package:playoncon/services/stable_hash.dart';
import 'package:timezone/data/latest_all.dart' as tz_data;
import 'package:timezone/timezone.dart' as tz;

Event _eventAt(DateTime start) => Event(
  id: 'e',
  title: 'Werewolf',
  startTime: start,
  endTime: start.add(const Duration(hours: 1)),
);

String _hex(String s) => fnv1a32(s).toRadixString(16).padLeft(8, '0');

void main() {
  group('sync error wording', () {
    // The raw exceptions carry the request URL, which includes the API key.
    final failures = <Object>[
      http.ClientException(
        'Failed host lookup',
        Uri.parse('https://sheets.googleapis.com/v4/x?key=SECRET-KEY'),
      ),
      const SocketException('Network is unreachable'),
      TimeoutException('Future not completed'),
      const HttpException('Sheets API HTTP 403: {"error": "SECRET-KEY"}'),
      const EmptyScheduleException(),
      const FormatException('Unexpected character'),
    ];

    for (final failure in failures) {
      test('${failure.runtimeType} is plain and reassuring', () {
        final message = ScheduleRepository.describeError(failure);
        expect(message, contains('saved copy'));
        expect(message, isNot(contains('SECRET-KEY')));
        expect(message, isNot(contains('http')));
        expect(message, isNot(contains('Exception')));
      });
    }
  });

  group('reminder fire time', () {
    tz_data.initializeTimeZones();
    final central = tz.getLocation('America/Chicago');
    final eastern = tz.getLocation('America/New_York');
    // The schedule's times are naive wall-clock values meaning venue time.
    final event = _eventAt(DateTime(2026, 7, 3, 19));
    final wellBefore = tz.TZDateTime(central, 2026, 7, 3, 12);

    test('no reminder never fires', () {
      expect(
        NotificationService.fireTime(event, const Reminder.none(), wellBefore),
        isNull,
      );
    });

    test('lead time is subtracted from the start, in venue time', () {
      final early = NotificationService.fireTime(
        event,
        const Reminder.minutes(15),
        wellBefore,
      );
      expect(early, tz.TZDateTime(central, 2026, 7, 3, 18, 45));
      expect(early!.location.name, 'America/Chicago');
      expect(
        NotificationService.fireTime(
          event,
          const Reminder.atStart(),
          wellBefore,
        ),
        tz.TZDateTime(central, 2026, 7, 3, 19),
      );
    });

    test('a phone still on Eastern gets the same instant', () {
      // 7 PM Central is 8 PM Eastern: saving at home must not schedule 7 PM
      // Eastern, an hour before the session.
      final fireAt = NotificationService.fireTime(
        event,
        const Reminder.atStart(),
        tz.TZDateTime(eastern, 2026, 7, 1, 9),
      );
      expect(
        fireAt!.isAtSameMomentAs(tz.TZDateTime(eastern, 2026, 7, 3, 20)),
        isTrue,
      );
    });

    test('a moment that has passed (or is now) is skipped', () {
      expect(
        NotificationService.fireTime(
          event,
          const Reminder.minutes(15),
          tz.TZDateTime(central, 2026, 7, 3, 18, 45),
        ),
        isNull,
      );
      expect(
        NotificationService.fireTime(
          event,
          const Reminder.atStart(),
          tz.TZDateTime(central, 2026, 7, 4),
        ),
        isNull,
      );
      // 7:30 PM Eastern is 6:30 PM Central: still ahead of a 6:45 reminder.
      expect(
        NotificationService.fireTime(
          event,
          const Reminder.minutes(15),
          tz.TZDateTime(eastern, 2026, 7, 3, 19, 30),
        ),
        isNotNull,
      );
    });
  });

  group('stable event IDs', () {
    test('the format is pinned', () {
      // If this changes, every saved session in the field is orphaned.
      expect(fnv1a32(''), 0x811c9dc5);
      expect(fnv1a32('a'), 0xe40c292c);
      expect(
        stableEventId('Welcome Wagon', DateTime(2026, 7, 2, 16), 'Theater'),
        '${_hex('Welcome Wagon')}_20260702T1600_${_hex('Theater')}',
      );
      expect(
        stableEventId('Welcome Wagon', DateTime(2026, 7, 2, 16), 'Theater'),
        matches(RegExp(r'^[0-9a-f]{8}_20260702T1600_[0-9a-f]{8}$')),
      );
    });

    test('the ID does not depend on the timezone of the DateTime', () {
      expect(
        stableEventId('X', DateTime.utc(2026, 7, 2, 16), 'Y'),
        stableEventId('X', DateTime(2026, 7, 2, 16), 'Y'),
      );
    });

    for (final path in [
      'assets/data/fallback-schedule.json',
      'test/fixtures/screenshot-schedule.json',
    ]) {
      test('$path carries the IDs the parser would produce', () {
        final events = (jsonDecode(File(path).readAsStringSync()) as List)
            .map((e) => Event.fromJson(e as Map<String, dynamic>))
            .toList();
        expect(events, isNotEmpty);
        for (final e in events) {
          expect(
            e.id,
            stableEventId(e.title, e.startTime, e.locationDisplayName!),
            reason: e.title,
          );
        }
        expect(events.map((e) => e.id).toSet().length, events.length);
      });
    }
  });

  group('saves after a sync', () {
    Event session(String title, DateTime start, String venue) => Event(
      id: stableEventId(title, start, venue),
      title: title,
      startTime: start,
      endTime: start.add(const Duration(hours: 1)),
      locationDisplayName: venue,
    );
    final fri7 = DateTime(2026, 7, 3, 19);
    final fri9 = DateTime(2026, 7, 3, 21);
    final werewolf = session('Werewolf', fri7, 'Theater');
    final karaoke = session('Karaoke', fri9, 'Lodge');
    final filler = [
      for (var i = 0; i < 10; i++) session('Filler $i', fri7, 'Room $i'),
    ];
    const remind = Reminder.minutes(15);

    test('an unchanged schedule changes nothing', () {
      final all = [werewolf, karaoke, ...filler];
      final plan = SavedReconciliation.plan({werewolf.id: remind}, all, all);
      expect(plan.isEmpty, isTrue);
    });

    test('a session that changes time keeps its save and reminder', () {
      final later = session('Werewolf', fri9, 'Theater');
      final plan = SavedReconciliation.plan(
        {werewolf.id: remind},
        [werewolf, karaoke, ...filler],
        [later, karaoke, ...filler],
      );
      expect(plan.dropped, isEmpty);
      expect(plan.moved.single.oldId, werewolf.id);
      expect(plan.moved.single.event.id, later.id);
      expect(plan.moved.single.reminder, remind);
    });

    test('a session that changes room keeps its save', () {
      final elsewhere = session('Werewolf', fri7, 'Lodge');
      final plan = SavedReconciliation.plan(
        {werewolf.id: remind},
        [werewolf, ...filler],
        [elsewhere, ...filler],
      );
      expect(plan.moved.single.event.id, elsewhere.id);
    });

    test('a cancelled or retitled session is dropped', () {
      final retitled = session('Werewolf: Ultimate', fri7, 'Theater');
      final plan = SavedReconciliation.plan(
        {werewolf.id: remind, 'left-over-from-an-old-format': remind},
        [werewolf, karaoke, ...filler],
        [retitled, karaoke, ...filler],
      );
      expect(plan.moved, isEmpty);
      expect(plan.dropped, {werewolf.id, 'left-over-from-an-old-format'});
    });

    test('a repeating session follows the slot in its own room', () {
      final other = session('Werewolf', fri7, 'Lodge');
      final movedHere = session('Werewolf', fri9, 'Theater');
      final movedThere = session('Werewolf', fri9, 'Lodge');
      final plan = SavedReconciliation.plan(
        {werewolf.id: remind},
        [werewolf, other, ...filler],
        [movedHere, movedThere, ...filler],
      );
      expect(plan.moved.single.event.id, movedHere.id);
    });

    test('an ambiguous move is dropped rather than guessed', () {
      final a = session('Werewolf', fri9, 'Lodge');
      final b = session('Werewolf', DateTime(2026, 7, 4, 19), 'Gazebo');
      final plan = SavedReconciliation.plan(
        {werewolf.id: remind},
        [werewolf, ...filler],
        [a, b, ...filler],
      );
      expect(plan.moved, isEmpty);
      expect(plan.dropped, [werewolf.id]);
    });

    test('two saves never land on the same session', () {
      final twin = session('Werewolf', fri7, 'Lodge');
      final only = session('Werewolf', fri9, 'Gazebo');
      final plan = SavedReconciliation.plan(
        {werewolf.id: remind, twin.id: remind},
        [werewolf, twin, ...filler],
        [only, ...filler],
      );
      expect(plan.moved.length, 1);
      expect(plan.dropped.length, 1);
    });

    test('a sync that lost a large part of the schedule touches nothing', () {
      // One sheet tab failing to parse looks like mass cancellation.
      final plan = SavedReconciliation.plan(
        {werewolf.id: remind},
        [werewolf, karaoke, ...filler],
        filler.take(6).toList(),
      );
      expect(plan.isEmpty, isTrue);
    });
  });

  group('server clock estimate', () {
    final server = DateTime.utc(2026, 7, 3, 19);

    test('falls back to the device clock before any live update', () {
      final device = DateTime.utc(2026, 7, 3, 19, 5);
      expect(ServerClock().now(device), device);
    });

    test('a phone running 5 minutes fast still sees a fresh cart as fresh', () {
      final clock = ServerClock();
      const fast = Duration(minutes: 5);
      // Arrived 300 ms after the server stamped it.
      clock.observe(server, server.add(fast + const Duration(milliseconds: 300)));
      final later = server.add(fast + const Duration(seconds: 30));
      final age = clock.now(later).difference(server);
      expect(age.inSeconds, inInclusiveRange(29, 30));
    });

    test('the quickest delivery wins over slow ones', () {
      final clock = ServerClock();
      final device = server.subtract(const Duration(minutes: 3)); // slow phone
      clock.observe(server, device.add(const Duration(seconds: 4)));
      clock.observe(server, device.add(const Duration(milliseconds: 200)));
      clock.observe(server, device.add(const Duration(seconds: 2)));
      expect(
        clock.now(device.add(const Duration(milliseconds: 200))),
        server,
      );
    });

    test('a corrected device clock is followed after a few updates', () {
      final clock = ServerClock();
      for (var i = 0; i < 25; i++) {
        final stamp = server.add(Duration(seconds: 10 * i));
        // First 5 updates on a clock an hour slow, then the user fixes it.
        final arrived = i < 5 ? stamp.subtract(const Duration(hours: 1)) : stamp;
        clock.observe(stamp, arrived);
      }
      final now = server.add(const Duration(seconds: 250));
      expect(clock.now(now), now);
    });
  });

  group('bundled descriptions', () {
    final cached = Event(
      id: 'w',
      title: 'Werewolf 🔥',
      startTime: DateTime(2026, 7, 3, 19),
      endTime: DateTime(2026, 7, 3, 20),
      details: 'Last release\u2019s wording.',
    );

    test('an app update\u2019s wording replaces the cached copy', () {
      final descriptions = EventDescriptions.fromMap({
        'Werewolf': 'This release\u2019s wording.',
      });
      expect(
        descriptions.enrich([cached]).single.details,
        'This release\u2019s wording.',
      );
    });

    test('an event the bundle doesn\u2019t know keeps what it has', () {
      final descriptions = EventDescriptions.fromMap({'Karaoke': 'Sing.'});
      expect(descriptions.enrich([cached]).single, same(cached));
    });
  });

  group('saved reminder decoding', () {
    test('reads the current and every legacy stored form', () {
      expect(Reminder.fromJsonValue(null), const Reminder.none());
      expect(Reminder.fromJsonValue(0), const Reminder.atStart());
      expect(Reminder.fromJsonValue(45), const Reminder.minutes(45));
      expect(Reminder.fromJsonValue('none'), const Reminder.none());
      expect(Reminder.fromJsonValue('atStart'), const Reminder.atStart());
      expect(
        Reminder.fromJsonValue('fifteenMinutesBefore'),
        const Reminder.minutes(15),
      );
      expect(Reminder.fromJsonValue('30'), const Reminder.minutes(30));
      expect(Reminder.fromJsonValue(<String>[]), const Reminder.none());
    });
  });

  group('event cache format', () {
    test('round-trips through JSON', () {
      final original = Event(
        id: 'a_1_b',
        title: 'Loooot!',
        startTime: DateTime(2026, 7, 3, 15),
        endTime: DateTime(2026, 7, 3, 17),
        locationKey: 'gaming',
        locationDisplayName: 'Main Gaming',
        details: 'Bring dice.',
        attributes: const ['SF'],
        subSchedule: [
          ScheduleItem(label: 'Tournament', time: DateTime(2026, 7, 3, 15, 30)),
        ],
      );
      final decoded = Event.fromJson(
        jsonDecode(jsonEncode(original.toJson())) as Map<String, dynamic>,
      );
      expect(decoded.toJson(), original.toJson());
    });

    test('reads a cache written before attributes and sub-schedules', () {
      final decoded = Event.fromJson({
        'id': 'x',
        'title': 'Welcome',
        'startTime': '2026-07-02T17:00:00.000',
        'endTime': '2026-07-02T18:00:00.000',
      });
      expect(decoded.attributes, isEmpty);
      expect(decoded.subSchedule, isEmpty);
    });

    test('sessions before 3 AM belong to the previous con day', () {
      expect(_eventAt(DateTime(2026, 7, 4, 1)).dayKey, '2026-07-03');
      expect(_eventAt(DateTime(2026, 7, 4, 3)).dayKey, '2026-07-04');
    });
  });

  group('atomic writes', () {
    late Directory directory;
    setUp(() => directory = Directory.systemTemp.createTempSync('poc-atomic'));
    tearDown(() => directory.deleteSync(recursive: true));

    test('replaces the file and leaves no temporary sibling', () async {
      final file = File('${directory.path}/saved_events.json')
        ..writeAsStringSync('{"old":null}');
      await writeStringAtomic(file, '{"new":15}');
      expect(file.readAsStringSync(), '{"new":15}');
      expect(directory.listSync(), hasLength(1));
    });

    test('a failed write keeps the previous contents', () async {
      final file = File('${directory.path}/gone/saved_events.json');
      await expectLater(
        writeStringAtomic(file, '{}'),
        throwsA(isA<FileSystemException>()),
      );
      expect(directory.listSync(), isEmpty);
    });
  });

  test('map projection rejects a non-finite coordinate', () {
    expect(MapGeoReference.instance.project(double.nan, -86.49), isNull);
  });
}
