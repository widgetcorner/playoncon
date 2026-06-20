import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../models/venue_location.dart';

/// Read/write helper for the venue hotspot list.
///
/// Source order:
///   1. `<appDocs>/locations_override.json` — written by the in-app editor
///   2. `assets/data/locations.json` — bundled with the app
///
/// The override file lets the developer calibrate hotspots on-device against
/// the real venue image without rebuilding. When ready to ship the new layout,
/// "Copy JSON" copies the same payload to the clipboard for paste into the
/// bundled asset, then "Reset" clears the override.
class LocationsStore {
  static const _overrideFileName = 'locations_override.json';

  Future<File> _overrideFile() async {
    final dir = await getApplicationDocumentsDirectory();
    return File('${dir.path}/$_overrideFileName');
  }

  Future<bool> hasOverride() async {
    final f = await _overrideFile();
    return f.exists();
  }

  Future<List<VenueLocation>> load() async {
    final f = await _overrideFile();
    if (await f.exists()) {
      try {
        return _decode(await f.readAsString());
      } catch (_) {
        // fall through to bundled
      }
    }
    return _decode(await rootBundle.loadString('assets/data/locations.json'));
  }

  Future<void> save(List<VenueLocation> locations) async {
    final f = await _overrideFile();
    await f.writeAsString(encode(locations));
  }

  Future<void> reset() async {
    final f = await _overrideFile();
    if (await f.exists()) await f.delete();
  }

  /// Pretty-printed JSON in the same shape the bundled asset uses.
  static String encode(List<VenueLocation> locations) {
    const enc = JsonEncoder.withIndent('  ');
    return enc.convert(locations.map((l) => l.toJson()).toList());
  }

  static List<VenueLocation> _decode(String raw) {
    final list = jsonDecode(raw) as List<dynamic>;
    return list
        .map((e) => VenueLocation.fromJson(e as Map<String, dynamic>))
        .toList();
  }
}

final locationsStoreProvider = Provider<LocationsStore>((_) => LocationsStore());

final venueLocationsProvider =
    FutureProvider<List<VenueLocation>>((ref) async {
  try {
    return await ref.read(locationsStoreProvider).load();
  } catch (_) {
    return const [];
  }
});
