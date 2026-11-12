import 'dart:io';

/// Replaces [file]'s contents without ever leaving it half-written.
///
/// Writes to a sibling temp file, flushes, then renames over the target — a
/// rename within one directory is atomic, so a crash or a kill mid-write
/// leaves the previous contents intact instead of a truncated JSON file that
/// would decode as "nothing saved".
Future<void> writeStringAtomic(File file, String contents) async {
  final temporary = File('${file.path}.tmp');
  try {
    await temporary.writeAsString(contents, flush: true);
    await temporary.rename(file.path);
  } finally {
    if (await temporary.exists()) await temporary.delete();
  }
}
