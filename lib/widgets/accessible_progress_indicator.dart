import 'package:flutter/material.dart';

/// Keeps loading feedback available when the user turns off animation.
class AccessibleProgressIndicator extends StatelessWidget {
  const AccessibleProgressIndicator({
    super.key,
    this.label = 'Loading',
    this.strokeWidth = 4,
  });

  final String label;
  final double strokeWidth;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: label,
      liveRegion: true,
      excludeSemantics: true,
      child: MediaQuery.disableAnimationsOf(context)
          ? Icon(
              Icons.hourglass_empty,
              color: Theme.of(context).colorScheme.primary,
            )
          : CircularProgressIndicator(strokeWidth: strokeWidth),
    );
  }
}
