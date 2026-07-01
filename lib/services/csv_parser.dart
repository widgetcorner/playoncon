import 'package:csv/csv.dart';

import '../models/event.dart';
import '../models/venue_location.dart';

/// A merged-cell range from a Google Sheet. `endRow`/`endCol` are exclusive,
/// matching the Sheets API v4 shape.
class CellMerge {
  final int startRow;
  final int endRow;
  final int startCol;
  final int endCol;
  const CellMerge({
    required this.startRow,
    required this.endRow,
    required this.startCol,
    required this.endCol,
  });

  int get rowSpan => endRow - startRow;

  bool contains(int r, int c) =>
      r >= startRow && r < endRow && c >= startCol && c < endCol;
}

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

    // Google's two CSV export endpoints behave differently:
    //   * pub?output=csv  — CRLF row breaks, bare LF inside quoted multi-line cells.
    //   * gviz/tq?…       — LF for everything (rows AND inside quoted cells).
    // Normalize CRLF→LF and parse with eol='\n'. The quote-aware tokenizer still
    // keeps multi-line cell content intact because LFs inside quotes are consumed
    // before the row-break check sees them.
    final normalized = csvText.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
    final rows = const CsvToListConverter(
      shouldParseNumbers: false,
      eol: '\n',
    ).convert(normalized);
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

  /// Merge-aware parse for the Sheets API v4 grid payload. Unlike [parse]
  /// (which walks a CSV and can only guess durations by patching each event's
  /// end time to the next non-empty cell — over-inflating events with empty
  /// follow-up slots), this reads the sheet's actual vertical merge spans:
  ///
  ///   * A 2-row merge → 2-hour event
  ///   * A 1-cell entry → 1-hour event (no more stretching to fill gaps)
  ///
  /// Horizontal header merges are how "Outdoors" spans two physical columns
  /// in the 2026 sheet — cells in the second column pick up the header via
  /// the merge anchor rather than being dropped as empty-header columns.
  List<Event> parseGrid(List<List<String>> rows, List<CellMerge> merges) {
    if (_eventThursday == null) return const [];
    if (rows.isEmpty) return const [];

    CellMerge? mergeContaining(int r, int c) {
      for (final m in merges) {
        if (m.contains(r, c)) return m;
      }
      return null;
    }

    String rawAt(int r, int c) {
      if (r < 0 || r >= rows.length) return '';
      final row = rows[r];
      if (c < 0 || c >= row.length) return '';
      return _normalizeWhitespace(row[c]);
    }

    // For any (r, c), returns the value at the cell's merge anchor. Cells
    // inside a merge come back empty from the API; only the anchor carries
    // `formattedValue`, so we always resolve through the anchor.
    String valueAt(int r, int c) {
      final m = mergeContaining(r, c);
      if (m == null) return rawAt(r, c);
      return rawAt(m.startRow, m.startCol);
    }

    // Locate the venue header row by finding "Theater" in column 1.
    var headerRowIdx = -1;
    for (var i = 0; i < rows.length; i++) {
      if (valueAt(i, 1).toLowerCase() == 'theater') {
        headerRowIdx = i;
        break;
      }
    }
    if (headerRowIdx < 0) return const [];

    // Row widths vary in the API response (trailing empties omitted). Column
    // extent is the max of any row length + any merge that reaches further.
    var maxCol = 0;
    for (final r in rows) {
      if (r.length > maxCol) maxCol = r.length;
    }
    for (final m in merges) {
      if (m.endCol > maxCol) maxCol = m.endCol;
    }

    final venueByCol = <int, String>{};
    for (var c = 1; c < maxCol; c++) {
      final v = valueAt(headerRowIdx, c);
      if (v.isEmpty) continue;
      // Skip the right-side mirror column (holds time labels like "4 PM").
      if (_parseTime(v) != null) continue;
      venueByCol[c] = v;
    }
    if (venueByCol.isEmpty) return const [];

    final events = <Event>[];
    DateTime? currentDayDate;
    int? prevHour;

    for (var i = headerRowIdx + 1; i < rows.length; i++) {
      final firstCell = valueAt(i, 0);

      final dayOffset = _dayOffsets[firstCell.toLowerCase()];
      if (dayOffset != null) {
        currentDayDate = _eventThursday.add(Duration(days: dayOffset));
        prevHour = null;
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

        final m = mergeContaining(i, col);
        // Skip cells that continue a merge — the event was already emitted at
        // the merge's top-left anchor row.
        if (m != null && (m.startRow != i || m.startCol != col)) continue;

        final rawCell = rawAt(i, col);
        if (rawCell.isEmpty) continue;

        final extracted = _extractAttributes(rawCell);
        final title = extracted.title;
        if (title.isEmpty) continue;

        final hours = m?.rowSpan ?? 1;
        final locKey = _resolveLocation(venue, rawCell)?.key;
        events.add(Event(
          id: _stableId(title, start, venue),
          title: title,
          startTime: start,
          endTime: start.add(Duration(hours: hours)),
          locationKey: locKey,
          locationDisplayName: venue,
          attributes: extracted.attributes,
        ));
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
  /// ⚠️ is stripped before the bare ⚠ fallback runs. The 🚫/🔥 pair replaced
  /// 🔞/🍷 mid-2026; both are accepted so older cached schedules keep working.
  static const List<(String, String)> _emojiAttributes = [
    ('🚫', '18+'),
    ('🔥', '21+'),
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
