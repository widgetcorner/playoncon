import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Physical edges, already resolved using the native view's layout direction.
/// A supported [AppleBarEdge.none] result must not invoke the unavailable-API fallback.
enum AppleBarEdge { unavailable, none, left, right }

@immutable
class AppleLayout {
  const AppleLayout({
    required this.barEdge,
    this.viewSize = Size.zero,
    this.occlusions = const [],
    this.divisions = const [],
  });

  const AppleLayout.unavailable()
    : barEdge = AppleBarEdge.unavailable,
      viewSize = Size.zero,
      occlusions = const [],
      divisions = const [];

  final AppleBarEdge barEdge;

  /// Size of the Flutter root view when the native snapshot was taken. Consumers
  /// can reject obsolete geometry while the display is transitioning.
  final Size viewSize;

  /// Active camera / Dynamic Island / window-control frames, in physical Flutter
  /// root-view logical pixels. Frames already contain interaction margins.
  /// Normal MediaQuery safe-area insets remain independent and are not repeated.
  final List<Rect> occlusions;

  /// Active fold frames in that same coordinate space. These divide content
  /// into usable regions rather than necessarily hiding pixels underneath.
  final List<Rect> divisions;

  factory AppleLayout.fromMessage(Object? message) {
    if (message is! Map) return const AppleLayout.unavailable();
    return AppleLayout(
      barEdge: switch (message['barEdge']) {
        'none' => AppleBarEdge.none,
        'left' => AppleBarEdge.left,
        'right' => AppleBarEdge.right,
        _ => AppleBarEdge.unavailable,
      },
      viewSize: Size(
        _finiteNumber(message['viewWidth']) ?? 0,
        _finiteNumber(message['viewHeight']) ?? 0,
      ),
      occlusions: _rectangles(message['occlusions']),
      divisions: _rectangles(message['divisions']),
    );
  }

  static double? _finiteNumber(Object? value) {
    if (value is! num || !value.isFinite) return null;
    return value.toDouble();
  }

  static List<Rect> _rectangles(Object? value) {
    if (value is! List) return const [];
    final result = <Rect>[];
    for (final item in value) {
      if (item is! Map) continue;
      final left = _finiteNumber(item['left']);
      final top = _finiteNumber(item['top']);
      final width = _finiteNumber(item['width']);
      final height = _finiteNumber(item['height']);
      if (left == null || top == null || width == null || height == null) {
        continue;
      }
      // A zero-width/height division can still separate two content regions.
      if (width < 0 || height < 0) continue;
      result.add(Rect.fromLTWH(left, top, width, height));
    }
    return List.unmodifiable(result);
  }
}

/// Flutter's Material bars do not consume UIKit's verticalBarEdge trait.
/// Older iOS versions and other platforms keep the app's adaptive fallback.
final appleLayoutProvider = StreamProvider<AppleLayout>((ref) async* {
  if (kIsWeb || defaultTargetPlatform != TargetPlatform.iOS) {
    yield const AppleLayout.unavailable();
    return;
  }
  try {
    yield* const EventChannel(
      'playoncon/apple_layout',
    ).receiveBroadcastStream().map(AppleLayout.fromMessage);
  } on MissingPluginException {
    yield const AppleLayout.unavailable();
  } on PlatformException {
    yield const AppleLayout.unavailable();
  }
});
