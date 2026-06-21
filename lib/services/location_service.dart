import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';

/// Streams the device position for the "you are here" dot.
///
/// Only listened to once the user enables location on the Map tab, so the app
/// never prompts for location at launch. Yields `null` when the location
/// service is off or permission is denied (the dot then stays hidden).
final currentPositionProvider =
    StreamProvider.autoDispose<Position?>((ref) async* {
  if (!await Geolocator.isLocationServiceEnabled()) {
    yield null;
    return;
  }
  var permission = await Geolocator.checkPermission();
  if (permission == LocationPermission.denied) {
    permission = await Geolocator.requestPermission();
  }
  if (permission == LocationPermission.denied ||
      permission == LocationPermission.deniedForever) {
    yield null;
    return;
  }
  yield* Geolocator.getPositionStream(
    locationSettings: const LocationSettings(
      accuracy: LocationAccuracy.high,
      distanceFilter: 4,
    ),
  );
});

/// Best-effort permission check/request used by the Map tab's locate button so
/// it can give immediate feedback (e.g. a "denied" snackbar).
Future<bool> ensureLocationPermission() async {
  if (!await Geolocator.isLocationServiceEnabled()) return false;
  var permission = await Geolocator.checkPermission();
  if (permission == LocationPermission.denied) {
    permission = await Geolocator.requestPermission();
  }
  return permission == LocationPermission.always ||
      permission == LocationPermission.whileInUse;
}
