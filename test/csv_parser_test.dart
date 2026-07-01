import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:playoncon/models/venue_location.dart';
import 'package:playoncon/services/csv_parser.dart';

void main() {
  test('parses 2025 grid CSV into events', () {
    final csv = File('test/fixtures/poc-schedule-2025.csv').readAsStringSync();
    final parser = CsvScheduleParser(
      const <VenueLocation>[],
      eventThursday: DateTime(2025, 7, 3),
    );
    final events = parser.parse(csv);

    expect(events, isNotEmpty,
        reason: 'parser should produce at least one event');

    // Spot-check a known cell from the sheet.
    final poolKickoff = events.firstWhere(
      (e) => e.title.contains('Kick Off Pool Party'),
      orElse: () => throw StateError('Kick Off Pool Party missing'),
    );
    expect(poolKickoff.startTime, DateTime(2025, 7, 3, 16, 0));
    expect(poolKickoff.locationDisplayName, 'Pool');

    // Late-night roll: Thursday "Midnight" → Friday 00:00
    final adultSwim = events.firstWhere(
      (e) =>
          e.title.contains('Adult Swim') &&
          e.startTime.day == 4 &&
          e.startTime.hour == 0,
      orElse: () => throw StateError('Adult Swim midnight roll missing'),
    );
    expect(adultSwim.startTime, DateTime(2025, 7, 4, 0, 0));

    // Day distribution: Thu/Fri/Sat/Sun all populated.
    final byDay = <String, int>{};
    for (final e in events) {
      byDay[e.dayKey] = (byDay[e.dayKey] ?? 0) + 1;
    }
    expect(byDay['2025-07-03'], greaterThan(0), reason: 'Thursday events');
    expect(byDay['2025-07-04'], greaterThan(0), reason: 'Friday events');
  });

  test('parses 2025 Saturday/Sunday tab', () {
    final csv = File('test/fixtures/poc-schedule-2025-satsun.csv')
        .readAsStringSync();
    final parser = CsvScheduleParser(
      const <VenueLocation>[],
      eventThursday: DateTime(2025, 7, 3),
    );
    final events = parser.parse(csv);
    final byDay = <String, int>{};
    for (final e in events) {
      byDay[e.dayKey] = (byDay[e.dayKey] ?? 0) + 1;
    }
    expect(byDay['2025-07-05'], greaterThan(0), reason: 'Saturday events');
    expect(byDay['2025-07-06'], greaterThan(0), reason: 'Sunday events');
    // ignore: avoid_print
    print('Sat/Sun tab: ${events.length} events: $byDay');
  });

  test('extracts [TAG] attributes and strips them from titles', () {
    // Synthetic CSV: minimal valid grid with tags in cells. CRLF row breaks
    // match the real Google Sheets export.
    final csv = [
      ',Theater,,Main Gaming\r\n',
      'Thursday,,,\r\n',
      '4 PM,[21+] [SF] Best at Drinking,,[NEW] Quiz Bowl\r\n',
      '5 PM,Welcome Wagon,,[A] Auditions!\r\n',
    ].join();

    final parser = CsvScheduleParser(
      const <VenueLocation>[],
      eventThursday: DateTime(2025, 7, 3),
    );
    final events = parser.parse(csv);

    final byTitle = {for (final e in events) e.title: e};

    final drink = byTitle['Best at Drinking']!;
    expect(drink.attributes, containsAll(['21+', 'SF']));
    expect(drink.title, isNot(contains('[')));

    // Unknown code should pass through verbatim — no app rebuild needed
    // when the sheet owner adds a new tag.
    final quiz = byTitle['Quiz Bowl']!;
    expect(quiz.attributes, ['NEW']);

    // No tags — empty list.
    expect(byTitle['Welcome Wagon']!.attributes, isEmpty);

    final aud = byTitle['Auditions!']!;
    expect(aud.attributes, ['A']);
  });

  test('extracts inline emoji attributes and strips them from titles', () {
    // 2026 schedule format: 🚫/🔞→18+, 🔥/🍷→21+, 🎓→AT, ⚠️→PG13, 🎧→SF.
    // The 🚫/🔥 pair replaced 🔞/🍷 mid-2026 — both are still accepted.
    final csv = [
      ',Theater,,Main Gaming\r\n',
      'Thursday,,,\r\n',
      '4 PM,Make a Holiday Card 🎓,,Holiday Party ⚠️\r\n',
      '5 PM,Adult Swim 🔥,,Coffee Service 🎧\r\n',
      '6 PM,After Dark Party 🚫,,Welcome Wagon\r\n',
      '7 PM,Wine Tasting 🍷,,Late Night 🔞\r\n',
    ].join();

    final parser = CsvScheduleParser(
      const <VenueLocation>[],
      eventThursday: DateTime(2026, 7, 2),
    );
    final byTitle = {for (final e in parser.parse(csv)) e.title: e};

    expect(byTitle['Make a Holiday Card']!.attributes, ['AT']);
    expect(byTitle['Holiday Party']!.attributes, ['PG13']);
    expect(byTitle['Adult Swim']!.attributes, ['21+']);
    expect(byTitle['Coffee Service']!.attributes, ['SF']);
    expect(byTitle['After Dark Party']!.attributes, ['18+']);
    expect(byTitle['Wine Tasting']!.attributes, ['21+']);
    expect(byTitle['Late Night']!.attributes, ['18+']);
    expect(byTitle['Welcome Wagon']!.attributes, isEmpty);
  });

  test('Outdoors events resolve to a pin via the (Location) title hint', () {
    const rect = NormalizedRect(x: 0, y: 0, w: 0.05, h: 0.05);
    final locations = [
      VenueLocation(key: 'theater', displayName: 'Theater', rect: rect),
      VenueLocation(
        key: 'recreation-field',
        displayName: 'Recreation Field',
        aliases: const ['Rec Field'],
        rect: rect,
      ),
      VenueLocation(
        key: 'mini-golf',
        displayName: 'Mini Golf Course',
        aliases: const ['Mini Golf', 'Mini-golf'],
        rect: rect,
      ),
      VenueLocation(
        key: 'picnic-tables',
        displayName: 'Picnic Tables, Canopy & Lower Mayfield',
        aliases: const ['Canopy'],
        rect: rect,
      ),
    ];

    final csv = [
      ',Theater,Outdoors\r\n',
      'Thursday,,\r\n',
      'Noon,Quiz Bowl,Cooler Yacht-Zee (Rec Field)\r\n',
      '1 PM,,Pokeball Hunt (Mini-golf)\r\n',
      '2 PM,,Color Wars (Canopy)\r\n',
      '3 PM,,Nature Run / Walk\r\n',
    ].join();

    final parser =
        CsvScheduleParser(locations, eventThursday: DateTime(2025, 7, 3));
    final byTitle = {for (final e in parser.parse(csv)) e.title: e};

    // Header resolves directly.
    expect(byTitle['Quiz Bowl']!.locationKey, 'theater');
    // "Outdoors" has no pin → resolve by the parenthetical hint.
    expect(byTitle['Cooler Yacht-Zee (Rec Field)']!.locationKey,
        'recreation-field');
    expect(byTitle['Pokeball Hunt (Mini-golf)']!.locationKey, 'mini-golf');
    expect(byTitle['Color Wars (Canopy)']!.locationKey, 'picnic-tables');
    // No hint, no matching header → unmatched (still listed in the schedule).
    expect(byTitle['Nature Run / Walk']!.locationKey, isNull);
  });

  test('sibling columns fan into one pin via aliases', () {
    const rect = NormalizedRect(x: 0, y: 0, w: 0.05, h: 0.05);
    final locations = [
      VenueLocation(
        key: 'gaming',
        displayName: 'Main Gaming',
        aliases: const ['RPG Room 1', 'Video Gaming'],
        rect: rect,
      ),
    ];
    final csv = [
      ',Theater,Main Gaming,RPG Room 1,Video Gaming\r\n',
      'Thursday,,,,\r\n',
      'Noon,Quiz Bowl,Open Gaming,Blood on the Clocktower,DJ Hero Tourney\r\n',
    ].join();

    final parser =
        CsvScheduleParser(locations, eventThursday: DateTime(2025, 7, 3));
    final byTitle = {for (final e in parser.parse(csv)) e.title: e};

    // All three gaming columns resolve to the single 'gaming' pin...
    expect(byTitle['Open Gaming']!.locationKey, 'gaming');
    expect(byTitle['Blood on the Clocktower']!.locationKey, 'gaming');
    expect(byTitle['DJ Hero Tourney']!.locationKey, 'gaming');
    // ...while each event keeps its own column label for the schedule/detail.
    expect(byTitle['Blood on the Clocktower']!.locationDisplayName, 'RPG Room 1');
    expect(byTitle['DJ Hero Tourney']!.locationDisplayName, 'Video Gaming');
    // No pin for Theater here → unmatched.
    expect(byTitle['Quiz Bowl']!.locationKey, isNull);
  });

  group('parseGrid (Sheets API merge-aware path)', () {
    test('vertical merge sets duration; adjacent 1-cell events do not stretch',
        () {
      // Layout (mirrors the shape of the 2026 sheet cells that were mis-parsed
      // as 4-hour events by the CSV path):
      //   row 0: header — cols 1=Theater, 2=Main Gaming
      //   row 2: Welcome (Theater) — 1 cell, should end at 5 PM
      //   row 3: Nidhogg (Main Gaming) — 2-row merge, should end at 7 PM
      //   row 4: (merge continuation — no event)
      //   row 5: Karaoke (Theater) — 1 cell, should end at 8 PM (NOT stretch)
      final rows = <List<String>>[
        ['', 'Theater', 'Main Gaming'],
        ['Thursday', '', ''],
        ['4 PM', 'Welcome', ''],
        ['5 PM', '', 'Nidhogg'],
        ['6 PM', '', ''],
        ['7 PM', 'Karaoke', ''],
      ];
      final merges = <CellMerge>[
        CellMerge(startRow: 3, endRow: 5, startCol: 2, endCol: 3),
      ];

      final parser = CsvScheduleParser(
        const <VenueLocation>[],
        eventThursday: DateTime(2026, 7, 2),
      );
      final events = parser.parseGrid(rows, merges);
      final byTitle = {for (final e in events) e.title: e};

      // 1-cell event stays 1 hour, no stretch-to-next.
      final welcome = byTitle['Welcome']!;
      expect(welcome.startTime, DateTime(2026, 7, 2, 16));
      expect(welcome.endTime, DateTime(2026, 7, 2, 17));

      // 2-row merge → 2 hours.
      final nidhogg = byTitle['Nidhogg']!;
      expect(nidhogg.startTime, DateTime(2026, 7, 2, 17));
      expect(nidhogg.endTime, DateTime(2026, 7, 2, 19));

      // Only one Nidhogg (merge continuation row emits nothing).
      expect(events.where((e) => e.title == 'Nidhogg').length, 1);

      // Late 1-cell event still 1 hour.
      final karaoke = byTitle['Karaoke']!;
      expect(karaoke.startTime, DateTime(2026, 7, 2, 19));
      expect(karaoke.endTime, DateTime(2026, 7, 2, 20));
    });

    test('horizontal header merge lets events in the second column '
        'inherit the header (Archery under a spanning Outdoors)', () {
      // Outdoors spans cols 2–3 as a horizontal header merge. Archery sits
      // in col 3, whose header cell is empty in the raw grid — API path only
      // sees the value via the merge anchor at (0, 2).
      final rows = <List<String>>[
        ['', 'Theater', 'Outdoors', ''],
        ['Thursday', '', '', ''],
        ['10 AM', '', '', 'Archery'],
      ];
      final merges = <CellMerge>[
        CellMerge(startRow: 0, endRow: 1, startCol: 2, endCol: 4),
      ];

      final parser = CsvScheduleParser(
        const <VenueLocation>[],
        eventThursday: DateTime(2026, 7, 2),
      );
      final events = parser.parseGrid(rows, merges);

      final archery = events.firstWhere(
        (e) => e.title == 'Archery',
        orElse: () => throw StateError('Archery missing from parseGrid output'),
      );
      expect(archery.locationDisplayName, 'Outdoors');
      expect(archery.startTime, DateTime(2026, 7, 2, 10));
    });

    test('parseGrid strips inline emoji attributes from titles', () {
      final rows = <List<String>>[
        ['', 'Theater'],
        ['Thursday', ''],
        ['4 PM', 'Adult Swim 🔥'],
      ];
      final parser = CsvScheduleParser(
        const <VenueLocation>[],
        eventThursday: DateTime(2026, 7, 2),
      );
      final events = parser.parseGrid(rows, const []);
      expect(events.first.title, 'Adult Swim');
      expect(events.first.attributes, ['21+']);
    });
  });
}
