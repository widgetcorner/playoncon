import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:playoncon/models/event.dart';
import 'package:playoncon/models/venue_location.dart';
import 'package:playoncon/services/csv_parser.dart';
import 'package:playoncon/services/sheets_api_client.dart';

import '../scripts/schedule_snapshot.dart';

void main() {
  final thursday = DateTime(2026, 7, 2);
  final locations = [
    VenueLocation(
      key: 'theater',
      displayName: 'Theater',
      rect: const NormalizedRect(x: 0, y: 0, w: 0.1, h: 0.1),
    ),
    VenueLocation(
      key: 'field',
      displayName: 'Recreation Field',
      aliases: const ['Rec Field'],
      rect: const NormalizedRect(x: 0.2, y: 0.2, w: 0.1, h: 0.1),
    ),
  ];
  final tab = SheetTab(
    gid: '10',
    rows: const [
      ['', 'Theater', 'Outdoors', ''],
      ['Thursday'],
      ['4 PM', 'Welcome Wagon 🎧', '', 'Beer Croquet (Rec Field) 🔥'],
      ['5 PM'],
      ['6 PM', 'Quiz Bowl'],
      ['Friday'],
      ['10 AM', 'Coffee'],
    ],
    merges: const [
      CellMerge(startRow: 0, endRow: 1, startCol: 2, endCol: 4),
      CellMerge(startRow: 2, endRow: 4, startCol: 1, endCol: 2),
    ],
  );

  ScheduleSnapshot build(
    List<SheetTab> tabs, {
    List<String> gids = const ['10'],
  }) => buildScheduleSnapshot(
    tabs: tabs,
    requestedGids: gids,
    locations: locations,
    eventThursday: thursday,
  );

  test('requires a real Thursday calendar date', () {
    expect(parseEventThursday('2026-07-02'), thursday);
    for (final bad in ['2026-02-31', '2026-7-2', '2026-07-03', 'wrong']) {
      expect(() => parseEventThursday(bad), throwsFormatException);
    }
  });

  test(
    'retains API merge duration, spanning header events, pins and attributes',
    () {
      final snapshot = build([tab]);
      expect(snapshot.events.length, 4);
      final welcome = snapshot.events.firstWhere(
        (event) => event.title == 'Welcome Wagon',
      );
      expect(
        welcome.endTime.difference(welcome.startTime),
        const Duration(hours: 2),
      );
      expect(welcome.attributes, ['SF']);
      final croquet = snapshot.events.firstWhere(
        (event) => event.title == 'Beer Croquet',
      );
      expect(croquet.locationKey, 'field');
      expect(croquet.attributes, ['21+']);
      expect(snapshot.matchedPinCount, 4);
      expect(snapshot.dayCounts, {'2026-07-02': 3, '2026-07-03': 1});
    },
  );

  test('refuses partial, duplicate, unexpected or empty tabs', () {
    expect(() => build([tab], gids: ['10', '20']), throwsFormatException);
    expect(() => build([tab, tab]), throwsFormatException);
    expect(() => build([tab], gids: ['10', '10']), throwsFormatException);
    expect(() => build([tab], gids: ['not-a-gid']), throwsFormatException);
    expect(
      () => build([const SheetTab(gid: '10', rows: [], merges: [])]),
      throwsFormatException,
    );
    expect(() => build([tab], gids: ['20']), throwsFormatException);
  });

  test('merges identical IDs across requested tabs as the repository does', () {
    final second = SheetTab(gid: '20', rows: tab.rows, merges: tab.merges);
    final snapshot = build([second, tab], gids: ['10', '20']);
    expect(snapshot.events.length, 4);
    expect(snapshot.duplicateCount, 4);
    expect(snapshot.tabCounts, {'10': 4, '20': 4});
  });

  test('refuses invalid merged ranges and impossible event durations', () {
    final invalidMerge = SheetTab(
      gid: '10',
      rows: tab.rows,
      merges: const [CellMerge(startRow: 2, endRow: 2, startCol: 1, endCol: 2)],
    );
    expect(() => build([invalidMerge]), throwsFormatException);
    final excessiveMerge = SheetTab(
      gid: '10',
      rows: tab.rows,
      merges: const [
        CellMerge(startRow: 2, endRow: 40, startCol: 1, endCol: 2),
      ],
    );
    expect(() => build([excessiveMerge]), throwsFormatException);
  });

  test('refuses sessions that roll beyond the convention date window', () {
    final bad = SheetTab(
      gid: '10',
      merges: const [],
      rows: const [
        ['', 'Theater'],
        ['Sunday'],
        ['10 PM', 'Late'],
        ['Midnight', 'Later'],
        ['10 PM', 'Wrong day'],
        ['Midnight', 'Too late'],
      ],
    );
    expect(() => build([bad]), throwsFormatException);
  });

  test(
    'counts descriptions shown after the app normalizes and enriches titles',
    () {
      final snapshot = build([tab]);
      expect(
        snapshot.effectiveDescriptionCount({
          '[SF] Welcome Wagon 🎧': 'Meet the con staff.',
          'Beer Croquet (Rec Field)': 'Play outdoors.',
          'Coffee': '   ',
          'Not scheduled': 'Unused copy.',
        }),
        2,
      );
    },
  );

  test(
    'decodes a native Sheets API replay through the production client',
    () async {
      final payload = {
        'sheets': [
          for (final gid in [10, 20])
            {
              'properties': {'sheetId': gid},
              'merges': [
                for (final merge in tab.merges)
                  {
                    'startRowIndex': merge.startRow,
                    'endRowIndex': merge.endRow,
                    'startColumnIndex': merge.startCol,
                    'endColumnIndex': merge.endCol,
                  },
              ],
              'data': [
                {
                  'rowData': [
                    for (final row in tab.rows)
                      {
                        'values': [
                          for (final cell in row) {'formattedValue': cell},
                        ],
                      },
                  ],
                },
              ],
            },
        ],
      };
      final client = SheetsApiClient(
        apiKey: 'fixture-key',
        spreadsheetId: 'fixture-id',
        httpClient: MockClient(
          (_) async => http.Response(
            jsonEncode(payload),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          ),
        ),
      );
      addTearDown(client.close);
      final snapshot = build(
        await client.fetchTabs(['20', '10']),
        gids: ['20', '10'],
      );
      expect(snapshot.tabCounts.keys, ['20', '10']);
      expect(snapshot.events.first.attributes, isNotEmpty);
      expect(snapshot.duplicateCount, 4);
    },
  );

  group('atomic snapshot replacement', () {
    late Directory temporary;
    late File output;
    setUp(() async {
      temporary = await Directory.systemTemp.createTemp('poc-import-test-');
      output = File('${temporary.path}/snapshot.json');
    });
    tearDown(() async => temporary.delete(recursive: true));

    Event event(int index) => Event(
      id: '$index',
      title: 'Session $index',
      startTime: thursday.add(Duration(hours: index)),
      endTime: thursday.add(Duration(hours: index + 1)),
      locationDisplayName: 'Theater',
    );
    ScheduleSnapshot snapshot(int count) => ScheduleSnapshot(
      [for (var i = 0; i < count; i++) event(i)],
      const {},
      0,
    );

    test(
      'large count drop preserves old bytes until explicitly reviewed',
      () async {
        await writeScheduleSnapshot(output, snapshot(10));
        final oldBytes = await output.readAsBytes();
        await expectLater(
          writeScheduleSnapshot(output, snapshot(7)),
          throwsFormatException,
        );
        expect(await output.readAsBytes(), oldBytes);
        expect(await temporary.list().length, 1);
        await writeScheduleSnapshot(output, snapshot(7), allowCountDrop: true);
        final decoded =
            jsonDecode(await output.readAsString()) as List<dynamic>;
        expect(decoded.length, 7);
        expect(
          Event.fromJson(decoded.first as Map<String, dynamic>).title,
          'Session 0',
        );
      },
    );

    test('a twenty percent count reduction is accepted', () async {
      await writeScheduleSnapshot(output, snapshot(10));
      await writeScheduleSnapshot(output, snapshot(8));
      expect((jsonDecode(await output.readAsString()) as List).length, 8);
      expect(await temporary.list().length, 1);
    });

    test(
      'empty snapshot and corrupt previous snapshot preserve existing data',
      () async {
        await output.writeAsString('corrupt snapshot');
        await expectLater(
          writeScheduleSnapshot(output, snapshot(0)),
          throwsFormatException,
        );
        await expectLater(
          writeScheduleSnapshot(output, snapshot(1)),
          throwsFormatException,
        );
        expect(await output.readAsString(), 'corrupt snapshot');
        expect(await temporary.list().length, 1);
      },
    );
  });
}
