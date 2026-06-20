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
}
