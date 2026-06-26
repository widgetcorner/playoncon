import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../config/app_config.dart';
import '../models/cart_position.dart';

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
///   2. Subscribes to Realtime INSERTs on `cart_positions`.
///   3. Periodically drops entries older than [_staleAfter].
final cartPositionsProvider =
    StreamProvider<Map<String, CartPosition>>((ref) {
  if (!AppConfig.hasSupabaseConfig) {
    return Stream<Map<String, CartPosition>>.value(const {});
  }

  final controller = StreamController<Map<String, CartPosition>>();
  final byCart = <String, CartPosition>{};
  final cartNames = <String, String>{};
  final client = Supabase.instance.client;
  RealtimeChannel? channel;
  Timer? sweep;
  var disposed = false;

  Map<String, CartPosition> snapshot() {
    final now = DateTime.now().toUtc();
    byCart.removeWhere((_, p) => now.difference(p.recordedAt) > _staleAfter);
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

      // Pull recent positions (last ~5 minutes) and reduce to latest-per-cart.
      // A small window keeps the initial fetch cheap as the table grows.
      final since = DateTime.now()
          .toUtc()
          .subtract(_staleAfter * 2)
          .toIso8601String();
      final rows = await client
          .from('cart_positions')
          .select(
              'cart_id, lat, lng, heading, speed, driver_name, recorded_at')
          .gte('recorded_at', since)
          .order('recorded_at', ascending: false);
      for (final row in rows) {
        final pos = CartPosition.fromJson(
          row,
          displayName: cartNames[row['cart_id'] as String],
        );
        final existing = byCart[pos.cartId];
        if (existing == null || pos.recordedAt.isAfter(existing.recordedAt)) {
          byCart[pos.cartId] = pos;
        }
      }
      emit();
    } catch (e) {
      debugPrint('cartPositions bootstrap failed: $e');
      emit(); // emit empty so the UI moves out of the loading state
    }

    if (disposed) return;

    channel = client
        .channel('public:cart_positions')
        .onPostgresChanges(
          event: PostgresChangeEvent.insert,
          schema: 'public',
          table: 'cart_positions',
          callback: (payload) {
            try {
              final row = payload.newRecord;
              final pos = CartPosition.fromJson(
                row,
                displayName: cartNames[row['cart_id'] as String?],
              );
              final existing = byCart[pos.cartId];
              if (existing == null ||
                  pos.recordedAt.isAfter(existing.recordedAt)) {
                byCart[pos.cartId] = pos;
                emit();
              }
            } catch (e) {
              debugPrint('cart_positions realtime decode failed: $e');
            }
          },
        )
        .subscribe();

    sweep = Timer.periodic(_sweepEvery, (_) => emit());
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
