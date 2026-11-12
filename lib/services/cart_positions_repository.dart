import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../config/app_config.dart';
import '../models/cart_position.dart';
import 'server_clock.dart';

/// How long a cart's last report stays "live" on the map. Drivers post every
/// ~10s; a 2-minute window forgives brief tunnels/garages without leaving
/// ghost carts on the map after a driver signs off.
const Duration _staleAfter = Duration(minutes: 2);

/// Sweep cadence — drops stale carts even when no new payloads arrive.
const Duration _sweepEvery = Duration(seconds: 30);

/// Live map of `cart_id` → latest [CartPosition].
///
/// Yields an empty map when Supabase isn't configured, so callers can watch
/// it unconditionally. When configured, the provider:
///   1. Loads the active carts (for `display_name`) and the latest position
///      per cart from `cart_positions`.
///   2. Subscribes to Realtime INSERTs and UPDATEs on `cart_positions`.
///   3. Periodically drops entries older than [_staleAfter], measured on the
///      server's clock as estimated by [ServerClock] — a phone with a wrong
///      clock would otherwise hide every cart, or keep ghosts around.
final cartPositionsProvider =
    StreamProvider<Map<String, CartPosition>>((ref) {
  if (!AppConfig.hasSupabaseConfig) {
    return Stream<Map<String, CartPosition>>.value(const {});
  }

  final controller = StreamController<Map<String, CartPosition>>();
  final byCart = <String, CartPosition>{};
  final cartNames = <String, String>{};
  // Carts whose name has been asked for since launch, so a nameless cart
  // posting every 10s triggers one lookup, not one per post.
  final nameRequested = <String>{};
  final client = Supabase.instance.client;
  final serverClock = ServerClock();
  RealtimeChannel? channel;
  Timer? sweep;
  var disposed = false;

  Map<String, CartPosition> snapshot() {
    final now = serverClock.now(DateTime.now().toUtc());
    byCart.removeWhere((_, p) => now.difference(p.updatedAt) > _staleAfter);
    return Map.unmodifiable(byCart);
  }

  void emit() {
    if (disposed || controller.isClosed) return;
    controller.add(snapshot());
  }

  Future<void> bootstrap() async {
    try {
      final carts = await client
          .from('carts')
          .select('id, display_name')
          .eq('active', true);
      for (final row in carts) {
        final id = row['id'] as String?;
        final name = row['display_name'] as String?;
        if (id != null && name != null) cartNames[id] = name;
      }

      // `post_position` upserts one row per cart, so this is one row per
      // cart ever registered — no time filter needed (a device-clock cutoff
      // would hide every cart on a phone whose clock runs fast). Stale rows
      // are dropped by the next snapshot.
      final rows = await client
          .from('cart_positions')
          .select(
              'cart_id, lat, lng, heading, speed, driver_name, updated_at')
          .order('updated_at', ascending: false);
      for (final row in rows) {
        final pos = CartPosition.fromJson(
          row,
          displayName: cartNames[row['cart_id'] as String],
        );
        final existing = byCart[pos.cartId];
        if (existing == null || pos.updatedAt.isAfter(existing.updatedAt)) {
          byCart[pos.cartId] = pos;
        }
      }
      emit();
    } catch (e) {
      debugPrint('cartPositions bootstrap failed: $e');
      emit(); // emit empty so the UI moves out of the loading state
    }

    if (disposed) return;

    // Drivers post via `post_position`, which UPSERTs one row per cart_id
    // (`ON CONFLICT DO UPDATE`). Postgres logical replication reports the
    // first post as INSERT and every subsequent post as UPDATE, so we listen
    // to both — otherwise carts would only appear on their first-ever post.
    // A cart registered after launch isn't in the bootstrap lookup, and
    // Realtime payloads don't carry `display_name` — fetch it once, then
    // patch the cart already on the map.
    Future<void> fetchName(String cartId) async {
      if (!nameRequested.add(cartId)) return;
      try {
        final row = await client
            .from('carts')
            .select('display_name')
            .eq('id', cartId)
            .maybeSingle();
        final name = row?['display_name'] as String?;
        if (name == null || disposed) return;
        cartNames[cartId] = name;
        final current = byCart[cartId];
        if (current != null && current.displayName == null) {
          byCart[cartId] = current.copyWith(displayName: name);
          emit();
        }
      } catch (e) {
        // Allow a retry on the next post rather than staying nameless.
        nameRequested.remove(cartId);
        debugPrint('cart name lookup failed: $e');
      }
    }

    void handleRow(Map<String, dynamic> row) {
      try {
        final pos = CartPosition.fromJson(
          row,
          displayName: cartNames[row['cart_id'] as String?],
        );
        serverClock.observe(pos.updatedAt, DateTime.now().toUtc());
        final existing = byCart[pos.cartId];
        if (existing == null || pos.updatedAt.isAfter(existing.updatedAt)) {
          byCart[pos.cartId] = pos;
          emit();
        }
        if (pos.displayName == null) unawaited(fetchName(pos.cartId));
      } catch (e) {
        debugPrint('cart_positions realtime decode failed: $e');
      }
    }

    channel = client
        .channel('public:cart_positions')
        .onPostgresChanges(
          event: PostgresChangeEvent.insert,
          schema: 'public',
          table: 'cart_positions',
          callback: (payload) => handleRow(payload.newRecord),
        )
        .onPostgresChanges(
          event: PostgresChangeEvent.update,
          schema: 'public',
          table: 'cart_positions',
          callback: (payload) => handleRow(payload.newRecord),
        )
        .subscribe();

    // Only emit when the sweep actually dropped a cart: every emit rebuilds
    // the map's pin overlay, and most ticks change nothing.
    sweep = Timer.periodic(_sweepEvery, (_) {
      final before = byCart.length;
      final current = snapshot();
      if (current.length != before && !disposed && !controller.isClosed) {
        controller.add(current);
      }
    });
  }

  bootstrap();

  ref.onDispose(() {
    disposed = true;
    sweep?.cancel();
    final ch = channel;
    if (ch != null) {
      // ignore: discarded_futures
      client.removeChannel(ch);
    }
    controller.close();
  });

  return controller.stream;
});
