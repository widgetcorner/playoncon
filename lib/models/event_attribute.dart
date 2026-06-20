import 'package:flutter/material.dart';

/// Display metadata for an event attribute code.
///
/// Codes come from `[TAG]` tokens in the source schedule cell text and are
/// stored uppercase on [Event.attributes]. Use [EventAttribute.resolve] to map
/// a raw code to a display label and icon.
///
/// Unknown codes resolve to a default pill that shows the raw code as its
/// label, so a brand-new tag added to the sheet shows up automatically without
/// requiring an app rebuild.
class EventAttribute {
  final String code;
  final String label;
  final IconData icon;

  const EventAttribute({
    required this.code,
    required this.label,
    required this.icon,
  });

  static const Map<String, EventAttribute> _known = {
    '21+': EventAttribute(
        code: '21+', label: 'Ages 21+ Only', icon: Icons.local_bar),
    'PG13': EventAttribute(
        code: 'PG13', label: 'Not for Children', icon: Icons.warning_amber),
    'AT': EventAttribute(
        code: 'AT', label: 'Apprentice Track', icon: Icons.school_outlined),
    'A': EventAttribute(
        code: 'A', label: 'Auditioned / Casted', icon: Icons.theater_comedy),
    'SF': EventAttribute(
        code: 'SF', label: 'Sensory Friendly', icon: Icons.spa_outlined),
    'OG': EventAttribute(
        code: 'OG',
        label: 'Sign up at Open Gaming',
        icon: Icons.app_registration),
  };

  /// Returns the metadata for [rawCode], falling back to a generic pill that
  /// surfaces the raw code unchanged.
  static EventAttribute resolve(String rawCode) {
    final norm = rawCode.toUpperCase().trim();
    final hit = _known[norm];
    if (hit != null) return hit;
    return EventAttribute(
      code: norm,
      label: norm,
      icon: Icons.local_offer_outlined,
    );
  }

  /// Every code we ship a built-in label/icon for. Used by an in-app legend.
  static List<EventAttribute> get knownAttributes =>
      _known.values.toSet().toList();
}
