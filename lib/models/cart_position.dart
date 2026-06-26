/// Most recent reported position of one golf cart.
///
/// Source of truth is the Supabase `cart_positions` table, written every
/// few seconds by the driver app. `displayName` is joined in from `carts`
/// — Realtime payloads carry only the columns of `cart_positions`, so the
/// repository fills it in from a cached carts lookup.
class CartPosition {
  final String cartId;
  final String? displayName;
  final double lat;
  final double lng;
  final double? heading;
  final double? speed;
  final String? driverName;
  final DateTime recordedAt;

  const CartPosition({
    required this.cartId,
    this.displayName,
    required this.lat,
    required this.lng,
    this.heading,
    this.speed,
    this.driverName,
    required this.recordedAt,
  });

  /// Decode a row from `cart_positions`. Tolerates missing `display_name`
  /// (Realtime payloads omit it) and missing optional metric fields.
  factory CartPosition.fromJson(
    Map<String, dynamic> json, {
    String? displayName,
  }) {
    return CartPosition(
      cartId: json['cart_id'] as String,
      displayName: displayName ??
          (json['display_name'] as String?) ??
          (json['carts'] is Map
              ? (json['carts'] as Map)['display_name'] as String?
              : null),
      lat: (json['lat'] as num).toDouble(),
      lng: (json['lng'] as num).toDouble(),
      heading: (json['heading'] as num?)?.toDouble(),
      speed: (json['speed'] as num?)?.toDouble(),
      driverName: json['driver_name'] as String?,
      recordedAt: DateTime.parse(json['recorded_at'] as String).toUtc(),
    );
  }

  CartPosition copyWith({String? displayName}) => CartPosition(
        cartId: cartId,
        displayName: displayName ?? this.displayName,
        lat: lat,
        lng: lng,
        heading: heading,
        speed: speed,
        driverName: driverName,
        recordedAt: recordedAt,
      );
}
