import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import '../config/app_config.dart';
import '../models/event.dart';
import 'csv_parser.dart';
import 'locations_store.dart';
import 'network_monitor.dart';

export 'locations_store.dart' show venueLocationsProvider;

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
  ScheduleRepository(this._ref) : super(ScheduleState.empty);

  final Ref _ref;
  static const _cacheFileName = 'schedule_cache.json';

  Future<void> bootstrap() async {
    final cached = await _readCache();
    if (cached.isNotEmpty) {
      state = state.copyWith(events: cached);
    } else {
      final fallback = await _loadFallback();
      if (fallback.isNotEmpty) {
        state = state.copyWith(events: fallback);
      }
    }
    if (AppConfig.hasScheduleUrl) {
      unawaited(refresh());
    }
  }

  Future<void> refresh() async {
    if (!AppConfig.hasScheduleUrl) {
      state = state.copyWith(errorMessage: 'Schedule URL not configured');
      return;
    }
    state = state.copyWith(isSyncing: true, clearError: true);
    try {
      final urls = AppConfig.scheduleCsvUrls;
      final locations = await _ref.read(venueLocationsProvider.future);
      final parser = CsvScheduleParser(
        locations,
        eventThursday: AppConfig.hasEventThursday
            ? DateTime.tryParse(AppConfig.eventThursday)
            : null,
      );

      final bodies = await Future.wait(urls.map((url) async {
        final resp = await http
            .get(Uri.parse(url))
            .timeout(const Duration(seconds: 20));
        if (resp.statusCode < 200 || resp.statusCode >= 300) {
          throw HttpException('HTTP ${resp.statusCode} for $url');
        }
        return resp.body;
      }));

      final merged = <String, Event>{};
      for (final body in bodies) {
        for (final e in parser.parse(body)) {
          merged[e.id] = e;
        }
      }
      final events = merged.values.toList();

      await _writeCache(events);
      state = ScheduleState(
        events: events,
        lastSyncAt: DateTime.now(),
        isSyncing: false,
      );
    } catch (e) {
      state = state.copyWith(isSyncing: false, errorMessage: e.toString());
    }
  }

  Future<File> _cacheFile() async {
    final dir = await getApplicationDocumentsDirectory();
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

  Future<void> _writeCache(List<Event> events) async {
    try {
      final file = await _cacheFile();
      final list = events.map((e) => e.toJson()).toList();
      await file.writeAsString(jsonEncode(list));
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
