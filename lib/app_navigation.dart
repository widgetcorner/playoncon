import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'services/last_tab_store.dart';

/// Selected bottom-nav tab in [RootShell]: 0 = Schedule, 1 = Map, 2 = Info.
/// Held in a provider (not local state) so any screen can switch tabs — e.g.
/// the "Show on map" deep-link from event detail.
///
/// Backed by [LastTabStore]: the choice persists across launches. The initial
/// value is loaded in `main.dart` and injected via a `ProviderScope` override,
/// so this builder is only hit if the override is missing.
final selectedTabProvider = StateNotifierProvider<LastTabStore, int>(
  (_) => throw StateError(
    'selectedTabProvider must be overridden in ProviderScope '
    '(see main.dart).',
  ),
);

/// Map tab index, named for readability at call sites.
const int mapTabIndex = 1;

/// A request to focus the venue map on a specific hotspot.
///
/// [seq] increments per dispatch so two requests for the *same* hotspot key
/// are still distinct objects — the map re-runs its focus animation each time
/// rather than ignoring a "no-op" state change.
class MapFocusRequest {
  final String locationKey;
  final int seq;
  const MapFocusRequest(this.locationKey, this.seq);
}

final mapFocusProvider = StateProvider<MapFocusRequest?>((_) => null);

extension MapFocusDispatch on WidgetRef {
  /// Switch to the Map tab and ask it to center + highlight [locationKey].
  void showOnMap(String locationKey) {
    final seq = (read(mapFocusProvider)?.seq ?? 0) + 1;
    read(mapFocusProvider.notifier).state = MapFocusRequest(locationKey, seq);
    read(selectedTabProvider.notifier).set(mapTabIndex);
  }
}
