import 'package:flutter/material.dart';

/// Used only while Reduce Motion is enabled. Removing spatial transitions also
/// removes the outgoing route's parallax; normal platform transitions remain
/// available when the setting is off.
const reducedMotionTransitions = PageTransitionsTheme(
  builders: {
    TargetPlatform.android: _StillPageTransitionsBuilder(),
    TargetPlatform.iOS: _StillPageTransitionsBuilder(),
    TargetPlatform.macOS: _StillPageTransitionsBuilder(),
    TargetPlatform.windows: _StillPageTransitionsBuilder(),
    TargetPlatform.linux: _StillPageTransitionsBuilder(),
    TargetPlatform.fuchsia: _StillPageTransitionsBuilder(),
  },
);

class _StillPageTransitionsBuilder extends PageTransitionsBuilder {
  const _StillPageTransitionsBuilder();

  @override
  Duration get transitionDuration => Duration.zero;

  @override
  Duration get reverseTransitionDuration => Duration.zero;

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) => child;
}
