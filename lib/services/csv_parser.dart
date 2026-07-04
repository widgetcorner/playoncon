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
    // (event index, whether that event's end was set explicitly by an in-title
    // time range — if so, later rows must not stretch it.)
    final lastEventInfoByVenue = <int, ({int idx, bool explicit})>{};
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
        lastEventInfoByVenue.clear();
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
        final rawMultiline = row[col].toString();
        final rawCell = _normalizeWhitespace(rawMultiline);
        if (rawCell.isEmpty) continue;

        // Split trailing "Label - H:MM AM/PM" lines off as sub-schedule
        // items; the event's own title is line 0.
        final sub = _extractSubSchedule(rawMultiline, start);
        final firstCell = _normalizeWhitespace(sub.titleText);
        if (firstCell.isEmpty) continue;

        final extracted = _extractAttributes(firstCell);
        var title = extracted.title;
        if (title.isEmpty) continue;

        final resolution = _resolveLocation(venue, firstCell);
        final locKey = resolution?.loc.key;
        var displayVenue = venue;
        if (resolution != null && resolution.hintDisplay != null) {
          displayVenue = resolution.hintDisplay!;
          title = _stripFirst(title, resolution.hintFullMatch!);
          if (title.isEmpty) continue;
        }

        var eventStart = start;
        var eventEnd = start.add(const Duration(hours: 1));
        final override = _extractTimeOverride(title, start.hour);
        final hasExplicitEnd = override != null && override.endHour != null;
        if (override != null) {
          title = override.cleanedTitle;
          if (title.isEmpty) continue;
          eventStart = DateTime(
            start.year, start.month, start.day,
            override.startHour, override.startMinute,
          );
          if (override.endHour != null) {
            var e = DateTime(
              start.year, start.month, start.day,
              override.endHour!, override.endMinute!,
            );
            if (override.endNextDay) e = e.add(const Duration(days: 1));
            eventEnd = e;
          } else {
            final minEnd = eventStart.add(const Duration(minutes: 30));
            if (eventEnd.isBefore(minEnd)) eventEnd = minEnd;
          }
        }

        // Patch the previous event at this venue to end when this slot starts —
        // unless it already set its end via an in-title range.
        final prevInfo = lastEventInfoByVenue[col];
        if (prevInfo != null && !prevInfo.explicit) {
          final prev = events[prevInfo.idx];
          events[prevInfo.idx] = _withEnd(prev, start);
        }

        events.add(Event(
          id: _stableId(title, eventStart, venue),
          title: title,
          startTime: eventStart,
          endTime: eventEnd,
          locationKey: locKey,
          locationDisplayName: displayVenue,
          attributes: extracted.attributes,
          subSchedule: sub.items,
        ));
        lastEventInfoByVenue[col] =
            (idx: events.length - 1, explicit: hasExplicitEnd);
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

    // Same as [rawAt], but preserves internal newlines so we can split off
    // per-line sub-schedule entries. Only used at merge anchors.
    String rawMultilineAt(int r, int c) {
      if (r < 0 || r >= rows.length) return '';
      final row = rows[r];
      if (c < 0 || c >= row.length) return '';
      return row[c];
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
        final rawMultiline = rawMultilineAt(i, col);

        final sub = _extractSubSchedule(rawMultiline, start);
        final firstCell = _normalizeWhitespace(sub.titleText);
        if (firstCell.isEmpty) continue;

        final extracted = _extractAttributes(firstCell);
        var title = extracted.title;
        if (title.isEmpty) continue;

        final hours = m?.rowSpan ?? 1;

        final resolution = _resolveLocation(venue, firstCell);
        final locKey = resolution?.loc.key;
        var displayVenue = venue;
        if (resolution != null && resolution.hintDisplay != null) {
          displayVenue = resolution.hintDisplay!;
          title = _stripFirst(title, resolution.hintFullMatch!);
          if (title.isEmpty) continue;
        }

        var eventStart = start;
        var eventEnd = start.add(Duration(hours: hours));
        final override = _extractTimeOverride(title, start.hour);
        if (override != null) {
          title = override.cleanedTitle;
          if (title.isEmpty) continue;
          eventStart = DateTime(
            start.year, start.month, start.day,
            override.startHour, override.startMinute,
          );
          if (override.endHour != null) {
            var e = DateTime(
              start.year, start.month, start.day,
              override.endHour!, override.endMinute!,
            );
            if (override.endNextDay) e = e.add(const Duration(days: 1));
            eventEnd = e;
          } else {
            final minEnd = eventStart.add(const Duration(minutes: 30));
            if (eventEnd.isBefore(minEnd)) eventEnd = minEnd;
          }
        }

        events.add(Event(
          id: _stableId(title, eventStart, venue),
          title: title,
          startTime: eventStart,
          endTime: eventEnd,
          locationKey: locKey,
          locationDisplayName: displayVenue,
          attributes: extracted.attributes,
          subSchedule: sub.items,
        ));
      }

      prevHour = t.hour;
    }

    return events;
  }

  /// Resolves a cell to a pin: first by exact column header, then — when the
  /// header is a broad category with no pin of its own (e.g. "Outdoors") — by
  /// a location hint parenthesized in the title, like "Beer Croquet (Rec Field)".
  ///
  /// When resolution comes via a hint (not the header), the record's
  /// [hintDisplay] holds the raw parenthetical text preserving case so the
  /// caller can use it as the event's `locationDisplayName` (replacing the
  /// broad category), and [hintFullMatch] holds the `(hint)` substring to
  /// strip from the title.
  ({VenueLocation loc, String? hintDisplay, String? hintFullMatch})?
      _resolveLocation(String header, String rawCell) {
    // A parenthesized title hint that matches a known pin wins over the
    // column header. Lets an author say "Apprentice Party (Lower Morrison
    // Dorm)" in the Lodge column and have the map link point to the dorm.
    for (final m in _hintRe.allMatches(rawCell)) {
      final raw = m.group(1)!;
      final norm = _normalizeHint(raw);
      if (norm.isEmpty) continue;
      final match = _byHint[norm];
      if (match != null) {
        return (
          loc: match,
          hintDisplay: _normalizeWhitespace(raw),
          hintFullMatch: m.group(0),
        );
      }
    }
    final direct = _byHeader[header.toLowerCase()];
    if (direct != null) {
      return (loc: direct, hintDisplay: null, hintFullMatch: null);
    }
    return null;
  }

  /// Lowercases and collapses punctuation to single spaces so "Rec Field",
  /// "rec field", and "Rec-Field" all compare equal.
  static String _normalizeHint(String s) =>
      s.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), ' ').trim();

  static final RegExp _hintRe = RegExp(r'\(([^)]+)\)');

  /// Removes the first occurrence of [needle] from [source] and collapses
  /// resulting whitespace.
  static String _stripFirst(String source, String needle) {
    final i = source.indexOf(needle);
    if (i < 0) return source;
    final out = '${source.substring(0, i)} ${source.substring(i + needle.length)}';
    return out.replaceAll(RegExp(r'\s+'), ' ').trim();
  }

  /// Range pattern for an in-title time override, e.g. "2-6 PM",
  /// "10 PM - 2 AM", "8:30-10:30 PM". Trailing meridiem is required so
  /// unrelated hyphens (`5-Card Draw`, `5-6 people`) don't match, and
  /// the expression is anchored to end-of-title so mid-title sub-schedule
  /// notes (`Learn to Play - 3 PM Tournament - 3:30 PM`) can't override.
  static final RegExp _rangeRe = RegExp(
    r'(\d{1,2})(?::(\d{2}))?(?:\s*(am|pm))?\s*[-–]\s*(\d{1,2})(?::(\d{2}))?\s*(am|pm)\s*$',
    caseSensitive: false,
  );

  /// Bare-start pattern requiring HH:MM (optional meridiem), anchored to
  /// end-of-title. Meridiem missing → inferred from the row's start hour.
  static final RegExp _bareStartRe = RegExp(
    r'(\d{1,2}):(\d{2})(?:\s*(am|pm))?\s*$',
    caseSensitive: false,
  );

  /// True when the char immediately before [start] (skipping spaces) is a
  /// dash — the `Label - Time` sub-schedule pattern Wes uses inside a
  /// merged block (`Loooot! ... Tournament - 3:30 PM`). Those times
  /// describe the event's internal schedule, not its own start/end.
  bool _precededByDash(String title, int start) {
    var i = start - 1;
    while (i >= 0 && (title[i] == ' ' || title[i] == '\t')) {
      i--;
    }
    if (i < 0) return false;
    final ch = title[i];
    return ch == '-' || ch == '–';
  }

  static int _to24(int h, String meridiem) {
    if (meridiem == 'am') return h == 12 ? 0 : h;
    return h == 12 ? 12 : h + 12; // pm
  }

  /// Parses an in-title time override (range or bare start). Returns null
  /// when no valid time expression is found. Callers use this to override
  /// the row-derived start (and, for a range, the merge- or stretch-derived
  /// end). Bare-start without a meridiem is disambiguated by [rowStartHour24].
  ({
    int startHour,
    int startMinute,
    int? endHour,
    int? endMinute,
    bool endNextDay,
    String cleanedTitle,
  })? _extractTimeOverride(String title, int rowStartHour24) {
    final range = _rangeRe.firstMatch(title);
    if (range != null && _precededByDash(title, range.start)) {
      // Descriptive sub-schedule ("Foo - 3-5 PM"), not the event's time.
      return null;
    }
    if (range != null) {
      final sh = int.parse(range.group(1)!);
      final sm = int.parse(range.group(2) ?? '0');
      final sMeridiem = range.group(3)?.toLowerCase();
      final eh = int.parse(range.group(4)!);
      final em = int.parse(range.group(5) ?? '0');
      final eMeridiem = range.group(6)!.toLowerCase();
      if (sh < 1 || sh > 12 || eh < 1 || eh > 12) return null;
      if (sm > 59 || em > 59) return null;

      var startAm = sMeridiem ?? eMeridiem;
      var sHour24 = _to24(sh, startAm);
      final eHour24 = _to24(eh, eMeridiem);
      // Shared meridiem but numerically start > end (e.g. "10-2 PM")
      // → start is opposite meridiem (10 AM → 2 PM).
      if (sMeridiem == null && sHour24 > eHour24) {
        startAm = eMeridiem == 'pm' ? 'am' : 'pm';
        sHour24 = _to24(sh, startAm);
      }
      final endNextDay = eHour24 < sHour24 ||
          (eHour24 == sHour24 && em < sm);

      final cleaned = title
          .replaceRange(range.start, range.end, ' ')
          .replaceAll(RegExp(r'\s+'), ' ')
          .trim();
      return (
        startHour: sHour24,
        startMinute: sm,
        endHour: eHour24,
        endMinute: em,
        endNextDay: endNextDay,
        cleanedTitle: cleaned,
      );
    }

    final bare = _bareStartRe.firstMatch(title);
    if (bare != null && _precededByDash(title, bare.start)) {
      // Descriptive sub-schedule ("Tournament - 3:30 PM"), not the event.
      return null;
    }
    if (bare != null) {
      final h = int.parse(bare.group(1)!);
      final m = int.parse(bare.group(2)!);
      final meridiem = bare.group(3)?.toLowerCase();
      if (m > 59) return null;
      if (meridiem != null && (h < 1 || h > 12)) return null;
      if (meridiem == null && (h < 0 || h > 23)) return null;

      final int hour24;
      if (meridiem != null) {
        hour24 = _to24(h, meridiem);
      } else if (h >= 13) {
        hour24 = h; // Already 24-hour form.
      } else {
        // Infer meridiem from the row's start hour. Row PM → assume PM.
        final rowIsPm = rowStartHour24 >= 12;
        hour24 = rowIsPm && h < 12 ? h + 12 : h;
      }

      final cleaned = title
          .replaceRange(bare.start, bare.end, ' ')
          .replaceAll(RegExp(r'\s+'), ' ')
          .trim();
      return (
        startHour: hour24,
        startMinute: m,
        endHour: null,
        endMinute: null,
        endNextDay: false,
        cleanedTitle: cleaned,
      );
    }
    return null;
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
        subSchedule: e.subSchedule,
      );

  /// Splits [raw] into an event title (all non–sub-schedule lines joined with
  /// spaces) and any lines that match `Label - H[:MM] [AM/PM]` (the trailing
  /// "Learn to Play - 3 PM / Tournament - 3:30 PM" pattern). A missing
  /// meridiem is inferred from [eventStart] — a PM row hour promotes
  /// single-digit hours to PM.
  ///
  /// Continuation lines that carry no dash (`Rocky Horror` / `Picture Show`)
  /// or a bare time (`11:30 PM`) fold back into the title so downstream
  /// [_extractAttributes] and [_extractTimeOverride] can pick up inline
  /// attribute markers and in-title start-time overrides regardless of which
  /// line they landed on.
  _SubScheduleExtract _extractSubSchedule(String raw, DateTime eventStart) {
    final lines = raw
        .split('\n')
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty)
        .toList(growable: false);
    if (lines.isEmpty) {
      return const _SubScheduleExtract(titleText: '', items: []);
    }
    if (lines.length == 1) {
      return _SubScheduleExtract(titleText: lines.first, items: const []);
    }
    final items = <ScheduleItem>[];
    final titleParts = <String>[];
    for (final line in lines) {
      final m = _subScheduleLineRe.firstMatch(line);
      if (m == null) {
        titleParts.add(line);
        continue;
      }
      final label = m.group(1)!.trim();
      if (label.isEmpty) {
        titleParts.add(line);
        continue;
      }
      final h = int.parse(m.group(2)!);
      final min = int.parse(m.group(3) ?? '0');
      final meridiem = m.group(4)?.toLowerCase();
      if (min > 59) {
        titleParts.add(line);
        continue;
      }

      final int hour24;
      if (meridiem != null) {
        if (h < 1 || h > 12) {
          titleParts.add(line);
          continue;
        }
        hour24 = _to24(h, meridiem);
      } else if (h >= 13 && h <= 23) {
        hour24 = h;
      } else if (h < 0 || h > 12) {
        titleParts.add(line);
        continue;
      } else {
        final rowIsPm = eventStart.hour >= 12;
        hour24 = rowIsPm && h < 12 ? h + 12 : h;
      }

      items.add(ScheduleItem(
        label: label,
        time: DateTime(
          eventStart.year, eventStart.month, eventStart.day,
          hour24, min,
        ),
      ));
    }
    return _SubScheduleExtract(
      titleText: titleParts.join(' '),
      items: items,
    );
  }

  /// Matches `Label - H[:MM][ AM/PM]` on a single sub-schedule line.
  static final RegExp _subScheduleLineRe = RegExp(
    r'^(.+?)\s*[-–]\s*(\d{1,2})(?::(\d{2}))?\s*(am|pm)?\s*$',
    caseSensitive: false,
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

class _SubScheduleExtract {
  final String titleText;
  final List<ScheduleItem> items;
  const _SubScheduleExtract({required this.titleText, required this.items});
}
