import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Wall-clock time used by the interface. Production reads the device clock;
/// store captures override it so the countdown, schedule position, and map
/// status remain reproducible when the screenshots are regenerated later.
final appClockProvider = Provider<DateTime Function()>((_) => DateTime.now);
