import 'dart:convert';
import 'dart:io';

import 'package:playoncon/models/event.dart';
import 'package:playoncon/models/venue_location.dart';
import 'package:playoncon/services/csv_parser.dart';
import 'package:playoncon/services/sheets_api_client.dart';

/// Refuse a loss of more than one fifth of the previous offline schedule.
/// A deliberate program reduction needs --allow-count-drop after review.
const maximumSnapshotCountDrop = 0.20;

DateTime parseEventThursday(String value) {
  if (!RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(value)) {
    throw const FormatException('Event Thursday must use YYYY-MM-DD.');
  }
  final date = DateTime.tryParse(value);
  if (date == null || date.toIso8601String().substring(0, 10) != value) {
    throw const FormatException('Event Thursday is not a valid calendar date.');
  }
  if (date.weekday != DateTime.thursday) {
    throw const FormatException('Event Thursday must fall on a Thursday.');
  }
  return date;
}

class ScheduleSnapshot {
  final List<Event> events;
  final Map<String, int> tabCounts;
  final int duplicateCount;

  const ScheduleSnapshot(this.events, this.tabCounts, this.duplicateCount);

  int get matchedPinCount =>
      events.where((event) => event.locationKey != null).length;

  Map<String, int> get dayCounts {
    final result = <String, int>{};
    for (final event in events) {
      result.update(event.dayKey, (count) => count + 1, ifAbsent: () => 1);
    }
    return result;
  }

  /// Mirrors EventDescriptions' title matching, counting the description the
  /// app actually displays after enrichment rather than only raw grid details.
  int effectiveDescriptionCount(Map<String, String> descriptions) {
    String normalize(String title) => title
        .replaceAll(RegExp(r'\[[A-Za-z0-9+\-/]{1,8}\]'), ' ')
        .replaceAll(RegExp(r'\([^)]*\)'), ' ')
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]+'), ' ')
        .trim();

    final byTitle = {
      for (final entry in descriptions.entries)
        normalize(entry.key): entry.value,
    };
    return events.where((event) {
      if (event.details?.trim().isNotEmpty == true) return true;
      return byTitle[normalize(event.title)]?.trim().isNotEmpty == true;
    }).length;
  }
}

/// Uses the app's merged-cell parser and ID merge, while rejecting a partial
/// response that would otherwise look like a successful smaller schedule.
ScheduleSnapshot buildScheduleSnapshot({
  required List<SheetTab> tabs,
  required List<String> requestedGids,
  required List<VenueLocation> locations,
  required DateTime eventThursday,
}) {
  parseEventThursday(eventThursday.toIso8601String().substring(0, 10));
  if (requestedGids.isEmpty ||
      requestedGids.toSet().length != requestedGids.length ||
      requestedGids.any((gid) => !RegExp(r'^\d+$').hasMatch(gid))) {
    throw const FormatException('Provide distinct numeric sheet gids.');
  }
  final byGid = <String, SheetTab>{};
  for (final tab in tabs) {
    if (!requestedGids.contains(tab.gid)) {
      throw FormatException('Unexpected sheet tab ${tab.gid}.');
    }
    if (byGid.containsKey(tab.gid)) {
      throw FormatException('Duplicate sheet tab ${tab.gid}.');
    }
    byGid[tab.gid] = tab;
  }
  final missing = requestedGids.where((gid) => !byGid.containsKey(gid));
  if (missing.isNotEmpty) {
    throw FormatException(
      'Requested sheet tabs missing: ${missing.join(', ')}.',
    );
  }

  final parser = CsvScheduleParser(locations, eventThursday: eventThursday);
  final merged = <String, Event>{};
  final counts = <String, int>{};
  var duplicateCount = 0;
  final earliest = eventThursday;
  // Sunday programming can roll through midnight into Monday morning.
  final latest = eventThursday.add(const Duration(days: 4, hours: 6));
  final locationKeys = locations.map((location) => location.key).toSet();
  for (final gid in requestedGids) {
    final tab = byGid[gid]!;
    for (final merge in tab.merges) {
      if (merge.startRow < 0 ||
          merge.startCol < 0 ||
          merge.endRow <= merge.startRow ||
          merge.endCol <= merge.startCol) {
        throw FormatException('Tab $gid contains an invalid merged range.');
      }
    }
    final events = parser.parseGrid(tab.rows, tab.merges);
    if (events.isEmpty) {
      throw FormatException('Tab $gid has no parseable schedule sessions.');
    }
    counts[gid] = events.length;
    for (final event in events) {
      if (event.id.trim().isEmpty ||
          event.title.trim().isEmpty ||
          event.locationDisplayName?.trim().isNotEmpty != true ||
          !event.endTime.isAfter(event.startTime) ||
          event.endTime.difference(event.startTime) >
              const Duration(hours: 24)) {
        throw FormatException('Tab $gid contains a malformed session.');
      }
      if (event.startTime.isBefore(earliest) ||
          !event.startTime.isBefore(latest) ||
          event.endTime.isAfter(latest)) {
        throw FormatException(
          'Tab $gid contains a session outside the configured convention dates.',
        );
      }
      if (event.locationKey != null &&
          !locationKeys.contains(event.locationKey)) {
        throw FormatException('Tab $gid contains an unknown venue pin.');
      }
      // Verify the exact bundled representation remains readable by the app.
      Event.fromJson(event.toJson());
      if (merged.containsKey(event.id)) duplicateCount++;
      merged[event.id] = event;
    }
  }
  final events = merged.values.toList()
    ..sort((a, b) {
      final byTime = a.startTime.compareTo(b.startTime);
      return byTime != 0 ? byTime : a.id.compareTo(b.id);
    });
  return ScheduleSnapshot(events, counts, duplicateCount);
}

/// Validate before creating a temporary sibling, then atomically replace the
/// snapshot. An error never truncates the last usable offline schedule.
Future<void> writeScheduleSnapshot(
  File output,
  ScheduleSnapshot snapshot, {
  bool allowCountDrop = false,
}) async {
  if (snapshot.events.isEmpty) {
    throw const FormatException('Refusing to write an empty schedule.');
  }
  if (await output.exists()) {
    final previous = jsonDecode(await output.readAsString()) as List<dynamic>;
    for (final value in previous) {
      Event.fromJson(value as Map<String, dynamic>);
    }
    if (!allowCountDrop &&
        snapshot.events.length <
            previous.length * (1 - maximumSnapshotCountDrop)) {
      throw FormatException(
        'Session count dropped from ${previous.length} to ${snapshot.events.length} '
        '(more than 20%). Review the source; use --allow-count-drop only for an intentional reduction.',
      );
    }
  }
  if (!await output.parent.exists()) {
    throw FileSystemException(
      'Output directory does not exist.',
      output.parent.path,
    );
  }
  final temporary = File(
    '${output.path}.tmp-$pid-${DateTime.now().microsecondsSinceEpoch}',
  );
  try {
    final serialized =
        '${const JsonEncoder.withIndent('  ').convert(snapshot.events.map((event) => event.toJson()).toList())}\n';
    await temporary.writeAsString(serialized, flush: true);
    await temporary.rename(output.path);
  } finally {
    if (await temporary.exists()) await temporary.delete();
  }
}
