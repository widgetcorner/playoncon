/// Estimates the server's clock from the timestamps of live updates, so cart
/// staleness doesn't depend on the phone's clock being right.
///
/// Every Realtime update carries the server's `now()` at write time and
/// arrives here a fraction of a second later. `deviceNow - serverStamp` is
/// therefore the clock difference plus network delay; the smallest recent
/// value is the best estimate of the difference alone. Until the first live
/// update arrives the device clock is used as-is.
class ServerClock {
  /// Recent samples only, so a clock the user corrects mid-session is
  /// followed within a few updates instead of being pinned to an old minimum.
  static const _window = 20;

  final List<Duration> _skews = [];

  /// Records one live update stamped [serverStamp] that arrived at [deviceNow].
  void observe(DateTime serverStamp, DateTime deviceNow) {
    _skews.add(deviceNow.difference(serverStamp));
    if (_skews.length > _window) _skews.removeAt(0);
  }

  /// The server's current time, as best known, given the device's [deviceNow].
  DateTime now(DateTime deviceNow) {
    if (_skews.isEmpty) return deviceNow;
    final skew = _skews.reduce((a, b) => a < b ? a : b);
    return deviceNow.subtract(skew);
  }
}
