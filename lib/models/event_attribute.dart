/// Display metadata for an event attribute code.
///
/// Codes come from `[TAG]` tokens in the source schedule cell text and are
/// stored uppercase on [Event.attributes]. Use [EventAttribute.resolve] to map
/// a raw code to a display label and leading emoji.
///
/// Unknown codes resolve to a default pill that shows the raw code as its
/// label with no emoji, so a brand-new tag added to the sheet shows up
/// automatically without requiring an app rebuild.
class EventAttribute {
  final String code;
  final String label;
  final String emoji;

  const EventAttribute({
    required this.code,
    required this.label,
    this.emoji = '',
  });

  static const Map<String, EventAttribute> _known = {
    '21+': EventAttribute(
        code: '21+', label: 'Ages 21+ Only', emoji: '🔞'),
    'PG13': EventAttribute(
        code: 'PG13', label: 'Not for Children', emoji: '⚠️'),
    'AT': EventAttribute(
        code: 'AT', label: 'Apprentice Track', emoji: '🎓'),
    'A': EventAttribute(
        code: 'A', label: 'Auditioned / Casted', emoji: '🎭'),
    'SF': EventAttribute(
        code: 'SF', label: 'Sensory Friendly', emoji: '🎧'),
    'OG': EventAttribute(
        code: 'OG', label: 'Sign up at Open Gaming', emoji: '🎲'),
  };

  /// Returns the metadata for [rawCode], falling back to a generic entry that
  /// surfaces the raw code unchanged with no emoji.
  static EventAttribute resolve(String rawCode) {
    final norm = rawCode.toUpperCase().trim();
    final hit = _known[norm];
    if (hit != null) return hit;
    return EventAttribute(code: norm, label: norm);
  }

  /// Every code we ship a built-in label for. Used by an in-app legend.
  static List<EventAttribute> get knownAttributes =>
      _known.values.toSet().toList();
}
