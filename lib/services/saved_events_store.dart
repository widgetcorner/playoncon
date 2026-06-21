import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

/// Reminder choice for a saved event, offered when the user saves it.
enum ReminderOption {
  none,
  atStart,
  fifteenMinutesBefore;

  /// How far before the start time the reminder fires, or null for no reminder.
  Duration? get leadTime {
    switch (this) {
      case ReminderOption.none:
        return null;
      case ReminderOption.atStart:
        return Duration.zero;
      case ReminderOption.fifteenMinutesBefore:
        return const Duration(minutes: 15);
    }
  }

  static ReminderOption fromName(String? s) => ReminderOption.values.firstWhere(
        (o) => o.name == s,
        orElse: () => ReminderOption.none,
      );
}

/// Persists the user's "My Schedule" as a map of event ID → reminder choice.
///
/// Offline-first, same pattern as the schedule cache: the source of truth is
/// `<appDocs>/saved_events.json`. An event is "saved" iff its ID is a key
/// (even with [ReminderOption.none]). IDs are the parser's stable
/// `title|start|location` hash, so saves survive a re-sync unless the cell
/// text/time/venue changes.
class SavedEventsStore extends StateNotifier<Map<String, ReminderOption>> {
  SavedEventsStore() : super(const {}) {
    _load();
  }

  static const _fileName = 'saved_events.json';

  Future<File> _file() async {
    final dir = await getApplicationDocumentsDirectory();
    return File('${dir.path}/$_fileName');
  }

  Future<void> _load() async {
    try {
      final f = await _file();
      if (!await f.exists()) return;
      final decoded = jsonDecode(await f.readAsString());
      if (decoded is Map) {
        state = decoded.map(
          (k, v) => MapEntry(k as String, ReminderOption.fromName(v as String?)),
        );
      } else if (decoded is List) {
        // Legacy format (array of IDs, pre-reminders) → no reminder.
        state = {for (final id in decoded) id as String: ReminderOption.none};
      }
    } catch (_) {
      // Corrupt/missing → empty.
    }
  }

  Future<void> _persist() async {
    try {
      final f = await _file();
      await f.writeAsString(
        jsonEncode(state.map((k, v) => MapEntry(k, v.name))),
      );
    } catch (_) {
      // Non-fatal; in-memory state still reflects the user's choice.
    }
  }

  bool isSaved(String id) => state.containsKey(id);

  ReminderOption reminderFor(String id) => state[id] ?? ReminderOption.none;

  void save(String id, ReminderOption reminder) {
    state = {...state, id: reminder};
    _persist();
  }

  void remove(String id) {
    if (!state.containsKey(id)) return;
    state = Map<String, ReminderOption>.of(state)..remove(id);
    _persist();
  }
}

final savedEventsProvider =
    StateNotifierProvider<SavedEventsStore, Map<String, ReminderOption>>(
        (_) => SavedEventsStore());
