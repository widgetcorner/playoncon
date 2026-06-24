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
    // 2026 schedule format: 🔞→18+, 🍷→21+, 🎓→AT, ⚠️→PG13, 🎧→SF.
    final csv = [
      ',Theater,,Main Gaming\r\n',
      'Thursday,,,\r\n',
      '4 PM,Make a Holiday Card 🎓,,Holiday Party ⚠️\r\n',
      '5 PM,Adult Swim 🍷,,Coffee Service 🎧\r\n',
      '6 PM,Party 🔞,,Welcome Wagon\r\n',
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
    expect(byTitle['Party']!.attributes, ['18+']);
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
}
