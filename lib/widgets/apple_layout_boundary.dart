import 'dart:math' as math;
import 'dart:ui' show DisplayFeature, DisplayFeatureState, DisplayFeatureType;

import 'package:flutter/widgets.dart';

import '../services/apple_layout.dart';

/// Active obstructions expressed in the hosting view's coordinates. Custom
/// edge controls can occupy a safe-area strip while avoiding its actual camera
/// and status controls, rather than excluding the entire strip a second time.
class AppleReservedRegions extends InheritedWidget {
  const AppleReservedRegions({
    super.key,
    required this.occlusions,
    required this.divisions,
    required this.viewSize,
    required this.barEdge,
    required super.child,
  });

  final List<Rect> occlusions;
  final List<Rect> divisions;
  final Size viewSize;
  final AppleBarEdge barEdge;

  static AppleReservedRegions? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AppleReservedRegions>();

  @override
  bool updateShouldNotify(AppleReservedRegions oldWidget) =>
      occlusions != oldWidget.occlusions ||
      divisions != oldWidget.divisions ||
      viewSize != oldWidget.viewSize ||
      barEdge != oldWidget.barEdge;
}

/// Applies scene-local reserved regions above the Navigator, so pushed pages
/// and dialogs receive the same usable geometry as the root destinations.
class AppleLayoutBoundary extends StatelessWidget {
  const AppleLayoutBoundary({
    super.key,
    required this.layout,
    required this.child,
  });

  final AppleLayout layout;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final size = media.size;
    // Native and Flutter geometry notifications can arrive in different frames.
    // Never apply a previous display's camera or fold to the new display.
    final current =
        (size.width - layout.viewSize.width).abs() < 1 &&
        (size.height - layout.viewSize.height).abs() < 1;
    var padding = media.padding;
    if (current) {
      for (final region in layout.occlusions) {
        final frame = region.intersect(Offset.zero & size);
        if (frame.isEmpty) continue;
        final content = Rect.fromLTRB(
          padding.left,
          padding.top,
          size.width - padding.right,
          size.height - padding.bottom,
        );
        if (!frame.overlaps(content)) continue;
        // Avoid the obstruction through its nearest edge. Use the union with
        // Flutter's insets rather than adding the same camera clearance twice.
        final distances = [
          frame.right,
          frame.bottom,
          size.width - frame.left,
          size.height - frame.top,
        ];
        final edge = distances.indexOf(distances.reduce(math.min));
        padding = EdgeInsets.fromLTRB(
          edge == 0 ? math.max(padding.left, distances[0]) : padding.left,
          edge == 1 ? math.max(padding.top, distances[1]) : padding.top,
          edge == 2 ? math.max(padding.right, distances[2]) : padding.right,
          edge == 3 ? math.max(padding.bottom, distances[3]) : padding.bottom,
        );
      }
    }
    final data = media.copyWith(
      padding: padding,
      viewPadding: EdgeInsets.fromLTRB(
        math.max(media.viewPadding.left, padding.left),
        math.max(media.viewPadding.top, padding.top),
        math.max(media.viewPadding.right, padding.right),
        math.max(media.viewPadding.bottom, padding.bottom),
      ),
      displayFeatures: [
        ...media.displayFeatures,
        if (current)
          for (final frame in layout.divisions)
            DisplayFeature(
              bounds: frame,
              type: DisplayFeatureType.fold,
              state: DisplayFeatureState.postureHalfOpened,
            ),
      ],
    );
    // Scrolling content and map artwork use the full display. Keep fold data
    // available for dialogs, sheets and individual floating controls to avoid
    // the crease locally, instead of moving the entire Navigator into one half.
    return MediaQuery(
      data: data,
      child: AppleReservedRegions(
        viewSize: size,
        barEdge: layout.barEdge,
        occlusions: current ? layout.occlusions : const [],
        divisions: current ? layout.divisions : const [],
        child: child,
      ),
    );
  }
}
