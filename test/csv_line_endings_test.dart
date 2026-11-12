import 'package:flutter_test/flutter_test.dart';
import 'package:playoncon/models/venue_location.dart';
import 'package:playoncon/services/csv_parser.dart';

void main() {
  // Regression: the gviz tab-name CSV export (added in commit 204cf86) uses
  // bare LF for row breaks, not CRLF. Without LF support the parser would
  // collapse the entire body into one row and produce zero events.
  test('parses CSV with bare-LF row separators', () {
    const csv =
        '"","Theater","Main Gaming","Outdoors"\n'
        '"Thursday","","",""\n'
        '"4 PM","Welcome","","Nature Walk"\n'
        '"5 PM","","Board Games",""\n';
    final parser = CsvScheduleParser(
      const <VenueLocation>[],
      eventThursday: DateTime(2026, 7, 2),
    );
    final events = parser.parse(csv);
    expect(events, hasLength(3));
    expect(events.first.title, 'Welcome');
    expect(events.first.startTime, DateTime(2026, 7, 2, 16, 0));
  });
}
