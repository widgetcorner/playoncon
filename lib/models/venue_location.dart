class VenueLocation {
  final String key;
  final String displayName;
  final NormalizedRect rect;

  VenueLocation({
    required this.key,
    required this.displayName,
    required this.rect,
  });

  VenueLocation copyWith({
    String? key,
    String? displayName,
    NormalizedRect? rect,
  }) =>
      VenueLocation(
        key: key ?? this.key,
        displayName: displayName ?? this.displayName,
        rect: rect ?? this.rect,
      );

  factory VenueLocation.fromJson(Map<String, dynamic> json) => VenueLocation(
        key: json['key'] as String,
        displayName: json['displayName'] as String,
        rect: NormalizedRect.fromJson(json['rect'] as Map<String, dynamic>),
      );

  Map<String, dynamic> toJson() => {
        'key': key,
        'displayName': displayName,
        'rect': rect.toJson(),
      };
}

class NormalizedRect {
  final double x;
  final double y;
  final double w;
  final double h;

  const NormalizedRect({
    required this.x,
    required this.y,
    required this.w,
    required this.h,
  });

  NormalizedRect copyWith({double? x, double? y, double? w, double? h}) =>
      NormalizedRect(
        x: x ?? this.x,
        y: y ?? this.y,
        w: w ?? this.w,
        h: h ?? this.h,
      );

  factory NormalizedRect.fromJson(Map<String, dynamic> json) => NormalizedRect(
        x: (json['x'] as num).toDouble(),
        y: (json['y'] as num).toDouble(),
        w: (json['w'] as num).toDouble(),
        h: (json['h'] as num).toDouble(),
      );

  Map<String, dynamic> toJson() => {'x': x, 'y': y, 'w': w, 'h': h};
}
