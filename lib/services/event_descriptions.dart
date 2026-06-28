import 'dart:convert';

import 'package:flutter/services.dart' show rootBundle;

import '../models/event.dart';

/// Look up long-form event descriptions extracted from the Play On Con
/// program (Google Doc) at build time and bundled with the app.
///
/// The schedule grid CSV only carries title/time/location/attributes — it
/// has no descriptions. This store fills in `Event.details` so the event
/// detail page can show real copy without a runtime fetch.
///
/// Keys are normalized titles (lowercased, attribute tags + emojis + paren
/// hints stripped, punctuation collapsed) so minor sheet-vs-doc wording
/// drift still matches. Title misses are silent — the event renders the
/// same as it did before descriptions existed.
class EventDescriptions {
  EventDescriptions._(this._byKey);

  final Map<String, String> _byKey;

  static EventDescriptions? _instance;

  /// Returns the singleton, loading the bundled JSON on first call.
  static Future<EventDescriptions> load() async {
    final cached = _instance;
    if (cached != null) return cached;
    try {
      final raw =
          await rootBundle.loadString('assets/data/event_descriptions.json');
      final map = jsonDecode(raw) as Map<String, dynamic>;
      final byKey = <String, String>{
        for (final entry in map.entries)
          _normalize(entry.key): (entry.value as String),
      };
      return _instance = EventDescriptions._(byKey);
    } catch (_) {
      return _instance = EventDescriptions._(const {});
    }
  }

  String? lookup(String title) => _byKey[_normalize(title)];

  /// Returns the input list with `details` populated where a description is
  /// known. Untouched events come through unchanged.
  List<Event> enrich(List<Event> events) {
    if (_byKey.isEmpty) return events;
    return events.map((e) {
      if (e.details != null && e.details!.isNotEmpty) return e;
      final hit = lookup(e.title);
      if (hit == null) return e;
      return e.copyWith(details: hit);
    }).toList(growable: false);
  }

  /// Strip attribute tags, emojis, parenthesized location hints, then
  /// lowercase and collapse non-alphanumerics to single spaces. Mirrors the
  /// matching philosophy of `CsvScheduleParser._normalizeHint`.
  static String _normalize(String s) {
    var t = s;
    t = t.replaceAll(RegExp(r'\[[A-Za-z0-9+\-/]{1,8}\]'), ' ');
    t = t.replaceAll(RegExp(r'\([^)]*\)'), ' ');
    return t.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), ' ').trim();
  }
}
