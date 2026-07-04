import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

/// One walked-and-tapped pairing: the GPS fix when the user said "I am here"
/// plus the normalized image coord of the hotspot they tapped to claim it.
///
/// Fed directly into `_ControlPoint` entries in
/// `lib/services/map_georeference.dart` to improve the affine fit.
class CalibrationPoint {
  final double lat;
  final double lng;
  final double x; // normalized image x (0..1)
  final double y; // normalized image y (0..1)
  final String hotspotKey;
  final double accuracyMeters;
  final DateTime capturedAt;

  const CalibrationPoint({
    required this.lat,
    required this.lng,
    required this.x,
    required this.y,
    required this.hotspotKey,
    required this.accuracyMeters,
    required this.capturedAt,
  });

  Map<String, dynamic> toJson() => {
        'lat': lat,
        'lng': lng,
        'x': x,
        'y': y,
        'hotspotKey': hotspotKey,
        'accuracyMeters': accuracyMeters,
        'capturedAt': capturedAt.toIso8601String(),
      };

  factory CalibrationPoint.fromJson(Map<String, dynamic> j) => CalibrationPoint(
        lat: (j['lat'] as num).toDouble(),
        lng: (j['lng'] as num).toDouble(),
        x: (j['x'] as num).toDouble(),
        y: (j['y'] as num).toDouble(),
        hotspotKey: j['hotspotKey'] as String,
        accuracyMeters: (j['accuracyMeters'] as num?)?.toDouble() ?? 0.0,
        capturedAt: DateTime.parse(j['capturedAt'] as String),
      );
}

class CalibrationStore {
  Future<File> _file() async {
    final dir = await getApplicationDocumentsDirectory();
    return File('${dir.path}/calibration_points.json');
  }

  Future<List<CalibrationPoint>> load() async {
    try {
      final f = await _file();
      if (!await f.exists()) return const [];
      final raw = await f.readAsString();
      final list = jsonDecode(raw) as List;
      return list
          .map((e) => CalibrationPoint.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (_) {
      return const [];
    }
  }

  Future<void> save(List<CalibrationPoint> points) async {
    final f = await _file();
    await f.writeAsString(jsonEncode(points.map((p) => p.toJson()).toList()));
  }

  Future<void> clear() async {
    final f = await _file();
    if (await f.exists()) await f.delete();
  }
}

/// Dart snippet suitable for pasting into `_points` in map_georeference.dart.
String calibrationPointsAsDart(List<CalibrationPoint> points) {
  final b = StringBuffer();
  for (final p in points) {
    final acc = p.accuracyMeters.toStringAsFixed(1);
    b.writeln(
      '_ControlPoint(${p.lat.toStringAsFixed(5)}, ${p.lng.toStringAsFixed(5)}, '
      '${p.x.toStringAsFixed(4)}, ${p.y.toStringAsFixed(4)}), '
      '// ${p.hotspotKey} (±${acc}m)',
    );
  }
  return b.toString();
}

class CalibrationPointsNotifier extends StateNotifier<List<CalibrationPoint>> {
  final CalibrationStore _store;
  CalibrationPointsNotifier(this._store) : super(const []) {
    _load();
  }

  Future<void> _load() async {
    state = await _store.load();
  }

  Future<void> add(CalibrationPoint p) async {
    state = [...state, p];
    await _store.save(state);
  }

  Future<void> undo() async {
    if (state.isEmpty) return;
    state = state.sublist(0, state.length - 1);
    await _store.save(state);
  }

  Future<void> clear() async {
    state = const [];
    await _store.clear();
  }
}

final calibrationStoreProvider = Provider((_) => CalibrationStore());

final calibrationPointsProvider =
    StateNotifierProvider<CalibrationPointsNotifier, List<CalibrationPoint>>(
  (ref) => CalibrationPointsNotifier(ref.watch(calibrationStoreProvider)),
);
