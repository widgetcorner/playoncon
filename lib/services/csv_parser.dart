import 'package:csv/csv.dart';

import '../models/event.dart';
import '../models/venue_location.dart';

/// Parses the Play On Con master schedule, which is a 2-D grid:
///
/// ```
///            | Theater | Main Gaming | RPG Rooms | ... | Lower Mayfield |
/// Thursday   |         |             |           |     |                |
/// 4 PM       |         |             |           |     |                |
/// 5 PM       | Welcome |             |           |     |                |
/// ...
/// Friday     |
/// 10 AM      | Stage   |             |           |     |                |
/// ```
///
/// Day-of-week rows reset the date; time rows in column 0 set the start time;
/// every non-empty cell at a venue column becomes one [Event].
class CsvScheduleParser {
  /// Column-header → pin. Keyed by lowercased displayName and each alias.
  final Map<String, VenueLocation> _byHeader;

  /// Normalized name → pin, for matching in-title location hints
  /// (e.g. "(Rec Field)"). Keyed by [_normalizeHint] of displayName + aliases.
  final Map<String, VenueLocation> _byHint;

  final DateTime? _eventThursday;

  CsvScheduleParser(
    List<VenueLocation> locations, {
    DateTime? eventThursday,
  })  : _byHeader = {
          for (final loc in locations) ...{
            loc.displayName.toLowerCase(): loc,
            for (final a in loc.aliases) a.toLowerCase(): loc,
          },
        },
        _byHint = {
          for (final loc in locations) ...{
            _normalizeHint(loc.displayName): loc,
            for (final a in loc.aliases) _normalizeHint(a): loc,
          },
        },
        _eventThursday = eventThursday == null
            ? null
            : DateTime(
                eventThursday.year,
                eventThursday.month,
                eventThursday.day,
              );

  static const Map<String, int> _dayOffsets = {
    'thursday': 0,
    'friday': 1,
    'saturday': 2,
    'sunday': 3,
  };

  List<Event> parse(String csvText) {
    if (_eventThursday == null) return const [];

    // Source uses CRLF for row breaks but bare LF inside quoted multi-line cells.
    // Default eol ('\r\n') correctly distinguishes the two.
    final rows = const CsvToListConverter(
      shouldParseNumbers: false,
    ).convert(csvText);
    if (rows.isEmpty) return const [];

    final venueRowIdx = _findVenueHeaderRow(rows);
    if (venueRowIdx < 0) return const [];

    final venueByCol = <int, String>{};
    final headerRow = rows[venueRowIdx];
    for (var c = 1; c < headerRow.length; c++) {
      final cleaned = _normalizeWhitespace(headerRow[c].toString());
      if (cleaned.isEmpty) continue;
      // Skip cells that are themselves time labels (right-side mirror column).
      if (_parseTime(cleaned) != null) continue;
      venueByCol[c] = cleaned;
    }
    if (venueByCol.isEmpty) return const [];

    final events = <Event>[];
    final lastEventIdxByVenue = <int, int>{};
    DateTime? currentDayDate;
    int? prevHour;

    for (var i = venueRowIdx + 1; i < rows.length; i++) {
      final row = rows[i];
      if (row.isEmpty) continue;
      final firstCell = row[0].toString().trim();

      // Day boundary
      final dayOffset = _dayOffsets[firstCell.toLowerCase()];
      if (dayOffset != null) {
        currentDayDate = _eventThursday.add(Duration(days: dayOffset));
        prevHour = null;
        lastEventIdxByVenue.clear();
        continue;
      }

      final t = _parseTime(firstCell);
      if (t == null) continue;
      if (currentDayDate == null) continue;

      // Late-night roll: prev was evening (>=8pm), now early morning (<6am)
      // → events belong to the next calendar day.
      if (prevHour != null && t.hour < 6 && prevHour >= 20) {
        currentDayDate = currentDayDate.add(const Duration(days: 1));
      }

      final start = DateTime(
        currentDayDate.year,
        currentDayDate.month,
        currentDayDate.day,
        t.hour,
        t.minute,
      );

      for (final entry in venueByCol.entries) {
        final col = entry.key;
        final venue = entry.value;
        if (col >= row.length) continue;
        final rawCell = _normalizeWhitespace(row[col].toString());
        if (rawCell.isEmpty) continue;

        final extracted = _extractAttributes(rawCell);
        final title = extracted.title;
        if (title.isEmpty) continue;

        // Patch the previous event at this venue to end when this slot starts.
        final prevIdx = lastEventIdxByVenue[col];
        if (prevIdx != null) {
          final prev = events[prevIdx];
          events[prevIdx] = _withEnd(prev, start);
        }

        final locKey = _resolveLocation(venue, rawCell)?.key;
        events.add(Event(
          id: _stableId(title, start, venue),
          title: title,
          startTime: start,
          endTime: start.add(const Duration(hours: 1)),
          locationKey: locKey,
          locationDisplayName: venue,
          attributes: extracted.attributes,
        ));
        lastEventIdxByVenue[col] = events.length - 1;
      }

      prevHour = t.hour;
    }

    return events;
  }

  /// Resolves a cell to a pin: first by exact column header, then — when the
  /// header is a broad category with no pin of its own (e.g. "Outdoors") — by
  /// a location hint parenthesized in the title, like "Beer Croquet (Rec Field)".
  VenueLocation? _resolveLocation(String header, String rawCell) {
    final direct = _byHeader[header.toLowerCase()];
    if (direct != null) return direct;
    for (final hint in _extractHints(rawCell)) {
      final match = _byHint[hint];
      if (match != null) return match;
    }
    return null;
  }

  /// Lowercases and collapses punctuation to single spaces so "Rec Field",
  /// "rec field", and "Rec-Field" all compare equal.
  static String _normalizeHint(String s) =>
      s.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), ' ').trim();

  static final RegExp _hintRe = RegExp(r'\(([^)]+)\)');

  /// Normalized location hints parenthesized in a title, e.g.
  /// "Pokeball Hunt (Mini-golf)" → ["mini golf"].
  static Iterable<String> _extractHints(String cell) sync* {
    for (final m in _hintRe.allMatches(cell)) {
      final h = _normalizeHint(m.group(1)!);
      if (h.isNotEmpty) yield h;
    }
  }

  int _findVenueHeaderRow(List<List<dynamic>> rows) {
    for (var i = 0; i < rows.length; i++) {
      final r = rows[i];
      if (r.length < 2) continue;
      final cell = r[1].toString().trim().toLowerCase();
      if (cell == 'theater') return i;
    }
    return -1;
  }

  static String _normalizeWhitespace(String s) {
    return s.replaceAll(RegExp(r'\s+'), ' ').trim();
  }

  /// Matches `[CODE]` tokens. Codes are 1–8 chars of letters/digits/`+ - /`.
  /// Permissive so a new tag the sheet owner invents (e.g. `[VIP]`, `[NEW]`)
  /// is picked up without parser changes.
  static final RegExp _attrRe =
      RegExp(r'\[([A-Za-z0-9+\-/]{1,8})\]');

  /// Inline emoji used as attribute tags in the 2026+ schedule, in priority
  /// order. Listed as (emoji, code) so the U+FE0F variation-selector form of
  /// ⚠️ is stripped before the bare ⚠ fallback runs.
  static const List<(String, String)> _emojiAttributes = [
    ('🔞', '18+'),
    ('🍷', '21+'),
    ('🎓', 'AT'),
    ('⚠️', 'PG13'),
    ('⚠', 'PG13'),
    ('🎧', 'SF'),
  ];

  static _ExtractedCell _extractAttributes(String cell) {
    final attrs = <String>[];
    var working = cell;

    for (final m in _attrRe.allMatches(working)) {
      final code = m.group(1)!.toUpperCase();
      if (!attrs.contains(code)) attrs.add(code);
    }
    working = working.replaceAll(_attrRe, ' ');

    for (final (emoji, code) in _emojiAttributes) {
      if (working.contains(emoji)) {
        if (!attrs.contains(code)) attrs.add(code);
        working = working.replaceAll(emoji, ' ');
      }
    }

    final stripped = working.replaceAll(RegExp(r'\s+'), ' ').trim();
    return _ExtractedCell(title: stripped, attributes: attrs);
  }

  static final RegExp _timeRe =
      RegExp(r'^(\d{1,2})(?::(\d{2}))?\s*(am|pm)$', caseSensitive: false);

  ({int hour, int minute})? _parseTime(String raw) {
    final s = raw.trim().toLowerCase();
    if (s.isEmpty) return null;
    if (s == 'noon') return (hour: 12, minute: 0);
    if (s == 'midnight') return (hour: 0, minute: 0);
    final m = _timeRe.firstMatch(s);
    if (m == null) return null;
    var h = int.parse(m.group(1)!);
    final min = int.parse(m.group(2) ?? '0');
    final ampm = m.group(3)!.toLowerCase();
    if (ampm == 'pm' && h != 12) h += 12;
    if (ampm == 'am' && h == 12) h = 0;
    if (h < 0 || h > 23 || min < 0 || min > 59) return null;
    return (hour: h, minute: min);
  }

  Event _withEnd(Event e, DateTime newEnd) => Event(
        id: e.id,
        title: e.title,
        startTime: e.startTime,
        endTime: newEnd,
        locationKey: e.locationKey,
        locationDisplayName: e.locationDisplayName,
        track: e.track,
        presenter: e.presenter,
        details: e.details,
        attributes: e.attributes,
      );

  String _stableId(String title, DateTime start, String location) {
    return '${title.hashCode}_${start.millisecondsSinceEpoch}_${location.hashCode}';
  }
}

class _ExtractedCell {
  final String title;
  final List<String> attributes;
  const _ExtractedCell({required this.title, required this.attributes});
}
