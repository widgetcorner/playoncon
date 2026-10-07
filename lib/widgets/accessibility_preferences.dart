import 'package:flutter/material.dart';

/// Flutter exposes Apple's Reduce Motion separately from Android's Remove
/// animations. Give app widgets one preference, updating it while open.
class AccessibilityPreferences extends StatefulWidget {
  const AccessibilityPreferences({super.key, required this.child});

  final Widget child;

  @override
  State<AccessibilityPreferences> createState() =>
      _AccessibilityPreferencesState();
}

class _AccessibilityPreferencesState extends State<AccessibilityPreferences>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAccessibilityFeatures() => setState(() {});

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final reduceMotion = View.of(
      context,
    ).platformDispatcher.accessibilityFeatures.reduceMotion;
    return MediaQuery(
      data: media.copyWith(
        disableAnimations: media.disableAnimations || reduceMotion,
      ),
      child: widget.child,
    );
  }
}
