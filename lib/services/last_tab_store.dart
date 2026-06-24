import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

/// Persists which bottom-nav tab the user was on last, so the next launch
/// resumes there. On first launch (no persisted value), starts on the Info
/// tab so new users land on the welcome screen with the address and countdown.
///
/// The initial state is loaded synchronously in `main.dart` before runApp and
/// injected as a [ProviderScope] override, so there's no flash from a
/// loading placeholder.
class LastTabStore extends StateNotifier<int> {
  LastTabStore(super.initial);

  static const int firstLaunchTab = 2;
  static const _fileName = 'last_tab.json';

  static Future<File> _file() async {
    final dir = await getApplicationDocumentsDirectory();
    return File('${dir.path}/$_fileName');
  }

  static Future<int> loadInitial() async {
    try {
      final f = await _file();
      if (!await f.exists()) return firstLaunchTab;
      final v = jsonDecode(await f.readAsString());
      if (v is int && v >= 0) return v;
    } catch (_) {
      // ignore — fall through to default
    }
    return firstLaunchTab;
  }

  Future<void> _persist() async {
    try {
      final f = await _file();
      await f.writeAsString(jsonEncode(state));
    } catch (_) {
      // Non-fatal; in-memory state still reflects the user's choice.
    }
  }

  void set(int index) {
    if (state == index) return;
    state = index;
    _persist();
  }
}
