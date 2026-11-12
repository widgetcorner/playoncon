import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint, visibleForTesting;
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import '../config/app_config.dart';
import '../models/event.dart';
import 'atomic_file.dart';
import 'event_descriptions.dart';
import 'locations_store.dart';
import 'network_monitor.dart';
import 'notification_service.dart';
import 'saved_events_store.dart';
import 'schedule_source.dart';

export 'locations_store.dart' show venueLocationsProvider;
export 'schedule_source.dart';

class ScheduleState {
  final List<Event> events;
  final DateTime? lastSyncAt;
  final bool isSyncing;
  final String? errorMessage;

  const ScheduleState({
    required this.events,
    this.lastSyncAt,
    this.isSyncing = false,
    this.errorMessage,
  });

  ScheduleState copyWith({
    List<Event>? events,
    DateTime? lastSyncAt,
    bool? isSyncing,
    String? errorMessage,
    bool clearError = false,
  }) {
    return ScheduleState(
      events: events ?? this.events,
      lastSyncAt: lastSyncAt ?? this.lastSyncAt,
      isSyncing: isSyncing ?? this.isSyncing,
      errorMessage: clearError ? null : (errorMessage ?? this.errorMessage),
    );
  }

  static const empty = ScheduleState(events: []);
}

final scheduleRepositoryProvider =
    StateNotifierProvider<ScheduleRepository, ScheduleState>((ref) {
  final repo = ScheduleRepository(ref);
  repo.bootstrap();
  ref.listen<AsyncValue<NetworkStatus>>(connectivityProvider, (prev, next) {
    final wasOffline = prev?.value?.isOnline == false;
    final nowOnline = next.value?.isOnline == true;
    if (wasOffline && nowOnline) {
      repo.refresh();
    }
  });
  return repo;
});

class ScheduleRepository extends StateNotifier<ScheduleState> {
  /// [source] and [documentsDirectory] default to the real sheet and the
  /// app's documents folder; tests pass fakes for both.
  ScheduleRepository(
    this._ref, {
    ScheduleSource? source,
    Future<Directory> Function()? documentsDirectory,
  }) : _source = source ?? ConfiguredScheduleSource(),
       _documentsDirectory =
           documentsDirectory ?? getApplicationDocumentsDirectory,
       super(ScheduleState.empty);

  final Ref _ref;
  final ScheduleSource _source;
  final Future<Directory> Function() _documentsDirectory;
  static const _cacheFileName = 'schedule_cache.json';

  /// The refresh currently in flight, if any. Launch, reconnect, the refresh
  /// buttons, and pull-to-refresh can all ask at once; they share one fetch
  /// rather than racing each other's cache writes.
  Future<void>? _refreshing;

  Future<void> bootstrap() async {
    final descriptions = await EventDescriptions.load();
    final cached = await _readCache();
    if (cached.isNotEmpty) {
      state = state.copyWith(
        events: descriptions.enrich(cached),
        // The cache is only ever written by a successful sync, so its
        // modified time is when this schedule was last fetched. Without this
        // the Info tab says "Last sync: Never" on every offline launch.
        lastSyncAt: await _cacheWrittenAt(),
      );
    } else {
      final fallback = await _loadFallback();
      if (fallback.isNotEmpty) {
        state = state.copyWith(events: descriptions.enrich(fallback));
      }
    }
    if (_source.isConfigured) {
      unawaited(refresh());
    }
  }

  Future<void> refresh() =>
      _refreshing ??= _refresh().whenComplete(() => _refreshing = null);

  Future<void> _refresh() async {
    if (!_source.isConfigured) {
      state = state.copyWith(errorMessage: 'Schedule source not configured');
      return;
    }
    state = state.copyWith(isSyncing: true, clearError: true);
    try {
      final locations = await _ref.read(venueLocationsProvider.future);
      final merged = await _source.fetch(locations);

      // The parser returns nothing (rather than throwing) when it can't find
      // the grid — a renamed "Theater" header, a wrong gid, a missing
      // POC_EVENT_THURSDAY. A real schedule is never empty, so treat that as
      // a failed sync and keep what we have instead of wiping the cache.
      if (merged.isEmpty) throw const EmptyScheduleException();

      final descriptions = await EventDescriptions.load();
      final events = descriptions.enrich(merged);

      final before = state.events;
      await _writeCache(events);
      if (!mounted) return; // provider torn down mid-sync
      state = ScheduleState(
        events: events,
        lastSyncAt: DateTime.now(),
        isSyncing: false,
      );
      await _reconcileSaves(before, events);
    } catch (e) {
      // The raw exception can carry the request URL (API key included) and
      // whole service response bodies — log it redacted, show plain words.
      debugPrint('Schedule refresh failed: ${_redact(e.toString())}');
      if (!mounted) return;
      state = state.copyWith(isSyncing: false, errorMessage: describeError(e));
    }
  }

  /// Follows moved sessions and clears saves (and their OS reminders) for
  /// sessions that left the schedule. Never fails the sync it rides on.
  Future<void> _reconcileSaves(List<Event> before, List<Event> after) async {
    try {
      final changes = await _ref
          .read(savedEventsProvider.notifier)
          .reconcile(before: before, after: after);
      if (changes.isEmpty) return;
      final notifications = _ref.read(notificationServiceProvider);
      for (final id in changes.dropped) {
        await notifications.cancel(id);
      }
      for (final move in changes.moved) {
        await notifications.cancel(move.oldId);
        await notifications.schedule(move.event, move.reminder);
      }
    } catch (e) {
      debugPrint('Saved-session reconciliation failed: $e');
    }
  }

  static String _redact(String message) {
    const key = AppConfig.sheetsApiKey;
    if (key.isEmpty) return message;
    return message
        .replaceAll(key, '[redacted]')
        .replaceAll(Uri.encodeComponent(key), '[redacted]');
  }

  /// Attendee-facing wording for a failed sync. Every branch says the saved
  /// schedule is still on screen, because that is the part they care about.
  @visibleForTesting
  static String describeError(Object error) {
    if (error is EmptyScheduleException) {
      return 'The schedule came back empty, so the saved copy was kept.';
    }
    if (error is TimeoutException) {
      return 'The schedule took too long to respond. Showing the saved copy.';
    }
    if (error is SocketException || error is http.ClientException) {
      return 'No connection to the schedule. Showing the saved copy.';
    }
    if (error is HttpException) {
      return 'The schedule service returned an error. Showing the saved copy.';
    }
    return 'The schedule could not be read. Showing the saved copy.';
  }

  Future<File> _cacheFile() async {
    final dir = await _documentsDirectory();
    return File('${dir.path}/$_cacheFileName');
  }

  Future<List<Event>> _readCache() async {
    try {
      final file = await _cacheFile();
      if (!await file.exists()) return const [];
      final raw = await file.readAsString();
      final list = jsonDecode(raw) as List<dynamic>;
      return list
          .map((e) => Event.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (_) {
      return const [];
    }
  }

  Future<DateTime?> _cacheWrittenAt() async {
    try {
      return await (await _cacheFile()).lastModified();
    } catch (_) {
      return null;
    }
  }

  Future<void> _writeCache(List<Event> events) async {
    try {
      final file = await _cacheFile();
      final list = events.map((e) => e.toJson()).toList();
      await writeStringAtomic(file, jsonEncode(list));
    } catch (_) {
      // Cache failure is non-fatal; UI keeps in-memory state.
    }
  }

  Future<List<Event>> _loadFallback() async {
    try {
      final raw =
          await rootBundle.loadString('assets/data/fallback-schedule.json');
      final list = jsonDecode(raw) as List<dynamic>;
      return list
          .map((e) => Event.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (_) {
      return const [];
    }
  }
}

/// A fetch that succeeded but parsed to zero sessions.
class EmptyScheduleException implements Exception {
  const EmptyScheduleException();

  @override
  String toString() => 'Schedule source parsed to zero sessions';
}
