import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../config/app_config.dart';
import '../models/event.dart';
import '../models/venue_location.dart';
import 'csv_parser.dart';
import 'sheets_api_client.dart';

/// Where [ScheduleRepository] gets a fresh schedule from. The repository owns
/// caching, error handling and saved-session fix-ups; a source only fetches
/// and parses, so tests can swap in a fake without any network.
abstract class ScheduleSource {
  /// False when no schedule location was compiled in; the repository then
  /// serves the cache / bundled schedule and never tries to sync.
  bool get isConfigured;

  /// Every session in the schedule, one per ID. May be empty when the sheet
  /// can't be parsed — the repository treats that as a failed sync.
  Future<List<Event>> fetch(List<VenueLocation> locations);
}

/// The production source, configured by the `--dart-define` values in
/// [AppConfig]: the Sheets API when its defines are set, else published CSV.
class ConfiguredScheduleSource implements ScheduleSource {
  @override
  bool get isConfigured => AppConfig.hasScheduleSource;

  @override
  Future<List<Event>> fetch(List<VenueLocation> locations) async {
    final parser = CsvScheduleParser(
      locations,
      eventThursday: AppConfig.hasEventThursday
          ? DateTime.tryParse(AppConfig.eventThursday)
          : null,
    );

    // Tabs can repeat a session (e.g. a day split across two tabs); the same
    // ID from two tabs is one session.
    final merged = <String, Event>{};
    if (AppConfig.hasSheetsApiConfig) {
      // Preferred path: Sheets API v4 with merged-cell data → real event
      // durations, no stretch-to-next-event heuristic.
      final client = SheetsApiClient(
        apiKey: AppConfig.sheetsApiKey,
        spreadsheetId: AppConfig.sheetId,
      );
      try {
        final tabs = await client.fetchTabs(AppConfig.sheetGids);
        for (final t in tabs) {
          for (final e in parser.parseGrid(t.rows, t.merges)) {
            merged[e.id] = e;
          }
        }
      } finally {
        client.close();
      }
    } else {
      // Fallback: CSV export. Durations default to 1 hour + a stretch-to-
      // next heuristic; kept so builds without the API defines still work.
      final urls = AppConfig.scheduleCsvUrls;
      final bodies = await Future.wait(
        urls.map((url) async {
          final resp = await http
              .get(Uri.parse(url))
              .timeout(const Duration(seconds: 20));
          if (resp.statusCode < 200 || resp.statusCode >= 300) {
            throw HttpException('HTTP ${resp.statusCode} for $url');
          }
          // Google's CSV export omits the charset on text/csv, so `resp.body`
          // would fall back to Latin-1 and mangle multi-byte emoji (🎓 → "ð…").
          return utf8.decode(resp.bodyBytes);
        }),
      );
      for (final body in bodies) {
        for (final e in parser.parse(body)) {
          merged[e.id] = e;
        }
      }
    }
    return merged.values.toList();
  }
}
