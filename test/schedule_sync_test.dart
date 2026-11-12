import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:playoncon/models/event.dart';
import 'package:playoncon/models/venue_location.dart';
import 'package:playoncon/services/notification_service.dart';
import 'package:playoncon/services/saved_events_store.dart';
import 'package:playoncon/services/schedule_repository.dart';
import 'package:playoncon/services/sheets_api_client.dart';
import 'package:playoncon/services/stable_hash.dart';

/// A schedule source whose next answer the test sets.
class _FakeSource implements ScheduleSource {
  FutureOr<List<Event>> Function() next = () => const [];
  int fetches = 0;

  @override
  bool get isConfigured => true;

  @override
  Future<List<Event>> fetch(List<VenueLocation> locations) async {
    fetches++;
    return next();
  }
}

class _RecordingNotifications extends NotificationService {
  final cancelled = <String>[];
  final scheduled = <String, Reminder>{};

  @override
  Future<void> cancel(String eventId) async => cancelled.add(eventId);

  @override
  Future<void> schedule(Event event, Reminder reminder) async =>
      scheduled[event.id] = reminder;
}

Event _session(String title, int hour, [String venue = 'Theater']) {
  final start = DateTime(2026, 7, 3, hour);
  return Event(
    id: stableEventId(title, start, venue),
    title: title,
    startTime: start,
    endTime: start.add(const Duration(hours: 1)),
    locationDisplayName: venue,
  );
}

final _filler = [for (var i = 0; i < 10; i++) _session('Filler $i', 12, 'R$i')];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory documents;
  late _FakeSource source;
  late _RecordingNotifications notifications;

  setUp(() async {
    documents = await Directory.systemTemp.createTemp('poc-sync-test-');
    source = _FakeSource();
    notifications = _RecordingNotifications();
  });
  tearDown(() => documents.delete(recursive: true));

  ProviderContainer container() {
    final c = ProviderContainer(
      overrides: [
        venueLocationsProvider.overrideWith((_) async => const []),
        notificationServiceProvider.overrideWithValue(notifications),
        savedEventsProvider.overrideWith(
          (_) => SavedEventsStore(documentsDirectory: () async => documents),
        ),
        scheduleRepositoryProvider.overrideWith(
          (ref) => ScheduleRepository(
            ref,
            source: source,
            documentsDirectory: () async => documents,
          ),
        ),
      ],
    );
    addTearDown(c.dispose);
    return c;
  }

  ScheduleRepository repoOf(ProviderContainer c) =>
      c.read(scheduleRepositoryProvider.notifier);

  test(
    'a good sync is shown, cached, and served offline next launch',
    () async {
      final schedule = [_session('Werewolf', 19), ..._filler];
      source.next = () => schedule;
      final first = container();
      await repoOf(first).refresh();
      final state = first.read(scheduleRepositoryProvider);
      expect(
        state.events.map((e) => e.id),
        unorderedEquals(schedule.map((e) => e.id)),
      );
      expect(state.errorMessage, isNull);
      expect(state.lastSyncAt, isNotNull);

      // Next launch, offline: the source fails, the cache still serves.
      source.next = () => throw const SocketException('offline');
      final second = container();
      await repoOf(second).bootstrap();
      await repoOf(second).refresh();
      final relaunched = second.read(scheduleRepositoryProvider);
      expect(relaunched.events, hasLength(schedule.length));
      expect(
        relaunched.lastSyncAt,
        isNotNull,
        reason: 'not "Last sync: Never"',
      );
      expect(relaunched.errorMessage, contains('saved copy'));
    },
  );

  test('an empty sync keeps the schedule and the cache', () async {
    source.next = () => [_session('Werewolf', 19), ..._filler];
    final c = container();
    await repoOf(c).refresh();

    source.next = () => const [];
    await repoOf(c).refresh();
    expect(c.read(scheduleRepositoryProvider).events, hasLength(11));
    expect(
      c.read(scheduleRepositoryProvider).errorMessage,
      contains('came back empty'),
    );

    final relaunch = container();
    await repoOf(relaunch).bootstrap();
    expect(relaunch.read(scheduleRepositoryProvider).events, hasLength(11));
  });

  test('a failed sync never shows the request URL or API key', () async {
    source.next = () => [_session('Werewolf', 19), ..._filler];
    final c = container();
    await repoOf(c).refresh();

    source.next = () => throw http.ClientException(
      'Connection reset',
      Uri.parse('https://sheets.googleapis.com/v4/x?key=SECRET-KEY'),
    );
    await repoOf(c).refresh();
    final state = c.read(scheduleRepositoryProvider);
    expect(state.events, hasLength(11));
    expect(state.isSyncing, isFalse);
    expect(state.errorMessage, isNot(contains('SECRET-KEY')));
    expect(state.errorMessage, contains('saved copy'));
  });

  test('refreshes asked for together share one fetch', () async {
    final release = Completer<List<Event>>();
    source.next = () => release.future;
    final c = container();
    final a = repoOf(c).refresh();
    final b = repoOf(c).refresh();
    release.complete([_session('Werewolf', 19), ..._filler]);
    await Future.wait([a, b]);
    expect(source.fetches, 1);

    // Once it has finished, the next refresh fetches again.
    await repoOf(c).refresh();
    expect(source.fetches, 2);
  });

  test('a saved session that moves keeps its save and reminder', () async {
    final werewolf = _session('Werewolf', 19);
    final cancelled = _session('Karaoke', 21);
    source.next = () => [werewolf, cancelled, ..._filler];
    final c = container();
    await repoOf(c).refresh();
    final saves = c.read(savedEventsProvider.notifier);
    saves.save(werewolf.id, const Reminder.minutes(15));
    saves.save(cancelled.id, const Reminder.atStart());

    final moved = _session('Werewolf', 20);
    source.next = () => [moved, ..._filler];
    await repoOf(c).refresh();

    expect(c.read(savedEventsProvider), {moved.id: const Reminder.minutes(15)});
    expect(notifications.cancelled, containsAll([werewolf.id, cancelled.id]));
    expect(notifications.scheduled, {moved.id: const Reminder.minutes(15)});

    // And it survives a relaunch.
    final relaunch = SavedEventsStore(
      documentsDirectory: () async => documents,
    );
    await pumpEventQueue();
    expect(relaunch.isSaved(moved.id), isTrue);
    expect(relaunch.isSaved(werewolf.id), isFalse);
  });

  group('saved sessions file', () {
    test(
      'the pre-reminder list format loads as saves with no reminder',
      () async {
        await File(
          '${documents.path}/saved_events.json',
        ).writeAsString(jsonEncode(['a', 'b']));
        final store = SavedEventsStore(
          documentsDirectory: () async => documents,
        );
        await pumpEventQueue();
        expect(store.state, {
          'a': const Reminder.none(),
          'b': const Reminder.none(),
        });
      },
    );

    test('a corrupt file loads as nothing saved', () async {
      await File('${documents.path}/saved_events.json').writeAsString('{nope');
      final store = SavedEventsStore(documentsDirectory: () async => documents);
      await pumpEventQueue();
      expect(store.state, isEmpty);
    });
  });

  group('Sheets API client', () {
    Map<String, Object> tab(int gid, String cell) => {
      'properties': {'sheetId': gid},
      'merges': [
        {
          'startRowIndex': 0,
          'endRowIndex': 2,
          'startColumnIndex': 1,
          'endColumnIndex': 2,
        },
      ],
      'data': [
        {
          'rowData': [
            {
              'values': [
                {'formattedValue': cell},
                <String, Object>{},
              ],
            },
          ],
        },
      ],
    };

    SheetsApiClient client(http.Response Function(http.Request) respond) {
      final c = SheetsApiClient(
        apiKey: 'k',
        spreadsheetId: 's',
        httpClient: MockClient((request) async => respond(request)),
      );
      addTearDown(c.close);
      return c;
    }

    http.Response json(Object body) => http.Response(
      jsonEncode(body),
      200,
      headers: {'content-type': 'application/json; charset=utf-8'},
    );

    test('returns tabs in the requested order with cells and merges', () async {
      final tabs = await client(
        (_) => json({
          'sheets': [tab(10, 'Thursday'), tab(20, 'Friday'), tab(30, 'Other')],
        }),
      ).fetchTabs(['20', '10']);
      expect(tabs.map((t) => t.gid), ['20', '10']);
      expect(tabs.first.rows, [
        ['Friday', ''],
      ]);
      final merge = tabs.first.merges.single;
      expect(
        [merge.startRow, merge.endRow, merge.startCol, merge.endCol],
        [0, 2, 1, 2],
      );
    });

    test('a requested tab missing from the workbook fails the fetch', () {
      expect(
        client(
          (_) => json({
            'sheets': [tab(10, 'Thursday')],
          }),
        ).fetchTabs(['10', '20']),
        throwsA(
          isA<MissingSheetTabsException>().having((e) => e.gids, 'gids', [
            '20',
          ]),
        ),
      );
    });

    test('an error status fails the fetch', () {
      expect(
        client(
          (_) => http.Response('{"error": "forbidden"}', 403),
        ).fetchTabs(['10']),
        throwsA(isA<HttpException>()),
      );
    });

    test('a body that is not JSON fails the fetch', () {
      expect(
        client((_) => http.Response('<html>', 200)).fetchTabs(['10']),
        throwsA(isA<FormatException>()),
      );
    });
  });
}
