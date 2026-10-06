// Run through scripts/refresh-schedule.sh for the configured release source.
// Native Sheets API responses can also be replayed with --grid-input FILE.
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:playoncon/models/venue_location.dart';
import 'package:playoncon/services/sheets_api_client.dart';

import 'schedule_snapshot.dart';

const usage = '''Usage: dart run scripts/import_schedule.dart [options]
  --sheet-id ID                 Spreadsheet ID (or SHEET_ID / POC_SHEET_ID)
  --gids GID[,GID...]            All release tab IDs (or SHEET_GIDS / POC_SHEET_GIDS)
  --event-thursday YYYY-MM-DD    Convention Thursday (or EVENT_THURSDAY / POC_EVENT_THURSDAY)
  --api-key KEY                 Prefer SHEETS_API_KEY / POC_SHEETS_API_KEY in the environment
  --locations FILE              Default: assets/data/locations.json
  --descriptions FILE           Default: assets/data/event_descriptions.json
  --output FILE                 Default: assets/data/fallback-schedule.json
  --grid-input FILE             Replay a native Sheets API JSON response, without network
  --allow-count-drop            Permit a reviewed reduction of more than 20%
  --help''';

Future<void> main(List<String> args) async {
  if (args.contains('--help')) {
    stdout.writeln(usage);
    return;
  }
  final options = <String, String>{};
  var allowCountDrop = false;
  const valueOptions = {
    '--sheet-id',
    '--gids',
    '--api-key',
    '--event-thursday',
    '--locations',
    '--descriptions',
    '--output',
    '--grid-input',
  };
  String? apiKey;
  try {
    for (var i = 0; i < args.length; i++) {
      final option = args[i];
      if (option == '--allow-count-drop') {
        allowCountDrop = true;
        continue;
      }
      if (!valueOptions.contains(option)) {
        throw const FormatException(
          'Unknown option. Run with --help for usage.',
        );
      }
      if (options.containsKey(option) ||
          i + 1 >= args.length ||
          args[i + 1].startsWith('--')) {
        throw FormatException('Missing or duplicate value for $option.');
      }
      options[option] = args[++i];
    }
    String? configured(String option, String local, String define) =>
        options[option] ??
        Platform.environment[local] ??
        Platform.environment[define];
    final sheetId = configured('--sheet-id', 'SHEET_ID', 'POC_SHEET_ID');
    final gidsValue = configured('--gids', 'SHEET_GIDS', 'POC_SHEET_GIDS');
    final dateValue = configured(
      '--event-thursday',
      'EVENT_THURSDAY',
      'POC_EVENT_THURSDAY',
    );
    apiKey = configured('--api-key', 'SHEETS_API_KEY', 'POC_SHEETS_API_KEY');
    final gridInput = options['--grid-input'];
    if (gidsValue == null ||
        dateValue == null ||
        (gridInput == null &&
            (sheetId == null ||
                sheetId.isEmpty ||
                apiKey == null ||
                apiKey.isEmpty))) {
      throw const FormatException(
        'Missing schedule configuration. Run with --help for usage.',
      );
    }
    final gids = gidsValue.split(',').map((gid) => gid.trim()).toList();
    final eventThursday = parseEventThursday(dateValue);
    final locationValues =
        jsonDecode(
              await File(
                options['--locations'] ?? 'assets/data/locations.json',
              ).readAsString(),
            )
            as List<dynamic>;
    final locations = locationValues
        .map((value) => VenueLocation.fromJson(value as Map<String, dynamic>))
        .toList();
    final descriptionsFile = File(
      options['--descriptions'] ?? 'assets/data/event_descriptions.json',
    );
    final descriptionValues =
        jsonDecode(await descriptionsFile.readAsString())
            as Map<String, dynamic>;
    final descriptions = descriptionValues.map(
      (key, value) => MapEntry(key, value as String),
    );
    http.Client? replay;
    if (gridInput != null) {
      final response = await File(gridInput).readAsString();
      replay = MockClient(
        (_) async => http.Response(
          response,
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        ),
      );
    }
    final client = SheetsApiClient(
      apiKey: apiKey ?? 'offline-replay',
      spreadsheetId: sheetId ?? 'offline-replay',
      httpClient: replay,
    );
    final tabs = await client.fetchTabs(gids).whenComplete(client.close);
    final snapshot = buildScheduleSnapshot(
      tabs: tabs,
      requestedGids: gids,
      locations: locations,
      eventThursday: eventThursday,
    );
    final output = File(
      options['--output'] ?? 'assets/data/fallback-schedule.json',
    );
    final first = snapshot.events.first.startTime.toIso8601String();
    final last = snapshot.events
        .map((event) => event.endTime)
        .reduce((a, b) => a.isAfter(b) ? a : b)
        .toIso8601String();
    final described = snapshot.effectiveDescriptionCount(descriptions);
    stdout.writeln(
      'Tabs: ${snapshot.tabCounts.entries.map((entry) => '${entry.key}: ${entry.value}').join(', ')}',
    );
    stdout.writeln(
      '${snapshot.events.length} unique sessions (${snapshot.duplicateCount} duplicate IDs merged).',
    );
    stdout.writeln('Date range: $first through $last');
    stdout.writeln(
      'Convention days: ${snapshot.dayCounts.entries.map((entry) => '${entry.key}: ${entry.value}').join(', ')}',
    );
    stdout.writeln(
      'Matched venue pins: ${snapshot.matchedPinCount}/${snapshot.events.length}',
    );
    stdout.writeln(
      'Effective description coverage: $described/${snapshot.events.length}',
    );
    await writeScheduleSnapshot(
      output,
      snapshot,
      allowCountDrop: allowCountDrop,
    );
    stdout.writeln('Wrote ${output.path}.');
  } catch (error) {
    // HTTP client exceptions can contain URLs or service response bodies.
    // Redact the configured API key before reporting any failure.
    var message = error.toString();
    if (apiKey != null && apiKey.isNotEmpty) {
      message = message.replaceAll(apiKey, '[redacted]');
      message = message.replaceAll(Uri.encodeComponent(apiKey), '[redacted]');
    }
    stderr.writeln('Schedule refresh failed: $message');
    stderr.writeln('The previous bundled schedule was preserved.');
    exitCode = 1;
  }
}
