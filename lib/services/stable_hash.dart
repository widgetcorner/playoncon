import 'dart:convert';

/// 32-bit FNV-1a over the UTF-8 bytes of [input].
///
/// Used wherever a hash is *persisted* (event IDs in `saved_events.json`,
/// notification IDs registered with the OS). `String.hashCode` is not an
/// option there: Dart only promises it is stable within one run, so an SDK
/// upgrade could silently change every saved ID.
int fnv1a32(String input) {
  var hash = 0x811c9dc5;
  for (final byte in utf8.encode(input)) {
    hash ^= byte;
    hash = (hash * 0x01000193) & 0xffffffff;
  }
  return hash;
}

/// The ID of the session titled [title] starting at [start] in [location].
///
/// [start] is the schedule's naive wall-clock time and is written out as
/// text (`20260702T1600`), never converted to an epoch: epoch milliseconds
/// depend on the device's timezone, which made the same session get a
/// different ID on a phone set to Eastern than on one set to Central.
String stableEventId(String title, DateTime start, String location) {
  String two(int n) => n.toString().padLeft(2, '0');
  String hex(String s) => fnv1a32(s).toRadixString(16).padLeft(8, '0');
  final wallClock =
      '${start.year}${two(start.month)}${two(start.day)}'
      'T${two(start.hour)}${two(start.minute)}';
  return '${hex(title)}_${wallClock}_${hex(location)}';
}
