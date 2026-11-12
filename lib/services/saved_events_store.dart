import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../models/event.dart';
import 'atomic_file.dart';

/// A saved event's reminder choice, expressed as minutes before the start.
///
/// - [leadMinutes] == null  → no reminder
/// - [leadMinutes] == 0      → at start time
/// - [leadMinutes]  > 0      → that many minutes before start (custom, 1–120)
class Reminder {
  final int? leadMinutes;
  const Reminder(this.leadMinutes);
  const Reminder.none() : leadMinutes = null;
  const Reminder.atStart() : leadMinutes = 0;
  const Reminder.minutes(int minutes) : leadMinutes = minutes;

  bool get isNone => leadMinutes == null;

  /// JSON value stored per event (`null` or an int).
  Object? toJsonValue() => leadMinutes;

  /// Tolerant decode: current int form, legacy enum-name strings, or null.
  static Reminder fromJsonValue(Object? v) {
    if (v == null) return const Reminder.none();
    if (v is int) return Reminder(v);
    if (v is String) {
      switch (v) {
        case 'none':
          return const Reminder.none();
        case 'atStart':
          return const Reminder.atStart();
        case 'fifteenMinutesBefore':
          return const Reminder.minutes(15);
      }
      final n = int.tryParse(v);
      if (n != null) return Reminder(n);
    }
    return const Reminder.none();
  }

  @override
  bool operator ==(Object other) =>
      other is Reminder && other.leadMinutes == leadMinutes;

  @override
  int get hashCode => leadMinutes.hashCode;
}

/// Persists the user's "My Schedule" as a map of event ID → [Reminder].
///
/// Offline-first, same pattern as the schedule cache: source of truth is
/// `<appDocs>/saved_events.json`. An event is "saved" iff its ID is a key
/// (even with a none reminder). IDs are the parser's `stableEventId`, so a
/// save survives a re-sync unless the cell text/time/venue changes — and
/// [SavedEventsReconciliation.reconcile] then follows a moved session.
class SavedEventsStore extends StateNotifier<Map<String, Reminder>> {
  /// [documentsDirectory] defaults to the app's documents folder; tests
  /// point it at a temporary one.
  SavedEventsStore({Future<Directory> Function()? documentsDirectory})
    : _documentsDirectory =
          documentsDirectory ?? getApplicationDocumentsDirectory,
      super(const {}) {
    _loaded = _load();
  }

  final Future<Directory> Function() _documentsDirectory;

  static const _fileName = 'saved_events.json';

  /// Completes once the file has been read. Writes wait on it, so a save
  /// tapped before the read finishes can't persist a one-entry map over the
  /// user's whole schedule.
  late final Future<void> _loaded;

  Future<File> _file() async {
    final dir = await _documentsDirectory();
    return File('${dir.path}/$_fileName');
  }

  Future<void> _load() async {
    try {
      final f = await _file();
      if (!await f.exists()) return;
      final decoded = jsonDecode(await f.readAsString());
      final Map<String, Reminder> onDisk;
      if (decoded is Map) {
        onDisk = decoded.map(
          (k, v) => MapEntry(k as String, Reminder.fromJsonValue(v)),
        );
      } else if (decoded is List) {
        // Legacy format (array of IDs, pre-reminders) → no reminder.
        onDisk = {
          for (final id in decoded) id as String: const Reminder.none(),
        };
      } else {
        return;
      }
      // Anything already in memory was saved while the read was in flight;
      // it is newer than the file, so it wins.
      state = {...onDisk, ...state};
    } catch (_) {
      // Corrupt/missing → empty.
    }
  }

  Future<void> _persist() async {
    try {
      await _loaded;
      final f = await _file();
      await writeStringAtomic(
        f,
        jsonEncode(state.map((k, v) => MapEntry(k, v.toJsonValue()))),
      );
    } catch (_) {
      // Non-fatal; in-memory state still reflects the user's choice.
    }
  }

  bool isSaved(String id) => state.containsKey(id);

  Reminder reminderFor(String id) => state[id] ?? const Reminder.none();

  void save(String id, Reminder reminder) {
    state = {...state, id: reminder};
    _persist();
  }

  void remove(String id) {
    if (!state.containsKey(id)) return;
    state = Map<String, Reminder>.of(state)..remove(id);
    _persist();
  }

  Future<SavedReconciliation> _reconcile(
    List<Event> before,
    List<Event> after,
  ) async {
    // Wait for the file: a sync can finish before the first read does.
    await _loaded;
    final plan = SavedReconciliation.plan(state, before, after);
    if (plan.isEmpty) return plan;
    final next = Map<String, Reminder>.of(state);
    for (final id in plan.dropped) {
      next.remove(id);
    }
    for (final move in plan.moved) {
      next.remove(move.oldId);
      next[move.event.id] = move.reminder;
    }
    state = next;
    await _persist();
    return plan;
  }
}

/// Kept off the class itself: the store-capture tool `implements`
/// [SavedEventsStore], so a new public member there would break it.
extension SavedEventsReconciliation on SavedEventsStore {
  /// Brings the saves in line with a freshly synced schedule: a save whose
  /// session moved follows it to the new ID, and a save whose session is gone
  /// is removed. Returns what changed so the caller can fix the reminders.
  Future<SavedReconciliation> reconcile({
    required List<Event> before,
    required List<Event> after,
  }) => _reconcile(before, after);
}

/// A save carried from [oldId] to the session's new entry, [event].
class MovedSave {
  final String oldId;
  final Event event;
  final Reminder reminder;
  const MovedSave(this.oldId, this.event, this.reminder);
}

/// What a sync did to the user's saves. See [SavedReconciliation.plan].
class SavedReconciliation {
  final List<MovedSave> moved;
  final List<String> dropped;
  const SavedReconciliation({this.moved = const [], this.dropped = const []});

  bool get isEmpty => moved.isEmpty && dropped.isEmpty;

  /// A sync that lost more than this share of the schedule is treated as a
  /// partly broken source (one tab failing to parse), not as cancellations,
  /// and leaves every save alone. Same threshold as `import_schedule.dart`.
  static const maxShrink = 0.2;

  /// Works out which [saved] IDs no longer exist in [after], and for each
  /// whether its session merely moved.
  ///
  /// An event's ID is its title + start + venue, so a session that changes
  /// time or room shows up as one ID vanishing and another appearing. A
  /// vanished save follows a newly appeared session with the **same title**
  /// when that match is unambiguous (the only one, or the only one in the
  /// same venue, or the only one at the same start). Anything else — a
  /// retitled, replaced or cancelled session — is dropped.
  static SavedReconciliation plan(
    Map<String, Reminder> saved,
    List<Event> before,
    List<Event> after,
  ) {
    if (after.length < before.length * (1 - maxShrink)) {
      return const SavedReconciliation();
    }
    final afterIds = {for (final e in after) e.id};
    final beforeById = {for (final e in before) e.id: e};
    final appeared = [
      for (final e in after)
        if (!beforeById.containsKey(e.id) && !saved.containsKey(e.id)) e,
    ];

    final moved = <MovedSave>[];
    final dropped = <String>[];
    for (final entry in saved.entries) {
      if (afterIds.contains(entry.key)) continue;
      final old = beforeById[entry.key];
      final target = old == null ? null : _successor(old, appeared);
      if (target == null) {
        dropped.add(entry.key);
      } else {
        appeared.remove(target);
        moved.add(MovedSave(entry.key, target, entry.value));
      }
    }
    return SavedReconciliation(moved: moved, dropped: dropped);
  }

  static Event? _successor(Event old, List<Event> appeared) {
    final sameTitle = appeared.where((e) => e.title == old.title).toList();
    if (sameTitle.length == 1) return sameTitle.single;
    final sameVenue = sameTitle
        .where((e) => e.locationDisplayName == old.locationDisplayName)
        .toList();
    if (sameVenue.length == 1) return sameVenue.single;
    final sameStart = sameTitle
        .where((e) => e.startTime == old.startTime)
        .toList();
    if (sameStart.length == 1) return sameStart.single;
    return null;
  }
}

final savedEventsProvider =
    StateNotifierProvider<SavedEventsStore, Map<String, Reminder>>(
        (_) => SavedEventsStore());

/// Remembers the last custom reminder lead time (in minutes) the user picked,
/// so it can be offered as a one-tap option when saving future events.
/// `null` until the user has chosen a custom time at least once.
class LastCustomReminderStore extends StateNotifier<int?> {
  LastCustomReminderStore() : super(null) {
    _load();
  }

  static const _fileName = 'last_custom_reminder.json';

  /// Set once the user picks a value, so a slow initial read can't put the
  /// older on-disk value back over it.
  bool _chosen = false;

  Future<File> _file() async {
    final dir = await getApplicationDocumentsDirectory();
    return File('${dir.path}/$_fileName');
  }

  Future<void> _load() async {
    try {
      final f = await _file();
      if (!await f.exists()) return;
      final v = jsonDecode(await f.readAsString());
      if (v is int && !_chosen) state = v;
    } catch (_) {
      // ignore
    }
  }

  Future<void> set(int minutes) async {
    _chosen = true;
    state = minutes;
    try {
      final f = await _file();
      await writeStringAtomic(f, jsonEncode(minutes));
    } catch (_) {
      // Non-fatal.
    }
  }
}

final lastCustomReminderProvider =
    StateNotifierProvider<LastCustomReminderStore, int?>(
        (_) => LastCustomReminderStore());
