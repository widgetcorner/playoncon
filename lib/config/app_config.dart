import 'package:timezone/timezone.dart' as tz;

class AppConfig {
  /// One or more published CSV URLs, comma-separated.
  /// Each URL is fetched and parsed independently; resulting events are merged.
  /// Use this to span multiple tabs of the same workbook.
  static const String scheduleCsvUrl =
      String.fromEnvironment('POC_SCHEDULE_CSV_URL');

  static List<String> get scheduleCsvUrls => scheduleCsvUrl
      .split(',')
      .map((s) => s.trim())
      .where((s) => s.isNotEmpty)
      .toList(growable: false);

  /// Human-viewable Google Sheet URL — the same source the CSV ingest reads,
  /// but in its browser-friendly form so attendees can pull up the full grid
  /// (or print it). Surfaced on the Info page; tile is hidden when unset.
  static const String scheduleViewUrl =
      String.fromEnvironment('POC_SCHEDULE_VIEW_URL');

  static const String discordInviteUrl =
      String.fromEnvironment('POC_DISCORD_INVITE_URL');

  static const String oneSignalAppId =
      String.fromEnvironment('POC_ONESIGNAL_APP_ID');

  /// Thursday of the convention, formatted yyyy-MM-dd.
  /// Used to anchor the grid-CSV schedule (which only carries day-of-week + time of day).
  static const String eventThursday =
      String.fromEnvironment('POC_EVENT_THURSDAY');

  static bool get hasScheduleUrl => scheduleCsvUrl.isNotEmpty;
  static bool get hasScheduleViewUrl => scheduleViewUrl.isNotEmpty;
  static bool get hasDiscordUrl => discordInviteUrl.isNotEmpty;
  static bool get hasOneSignalId => oneSignalAppId.isNotEmpty;
  static bool get hasEventThursday => eventThursday.isNotEmpty;

  /// Convention kickoff: 4:00 PM Central on Thursday of Play On Con.
  /// Anchored to America/Chicago (the venue's timezone) so the countdown is
  /// correct regardless of where the user's device thinks it is. Returns null
  /// if [POC_EVENT_THURSDAY] is unset or unparseable.
  ///
  /// Relies on the timezone DB being initialized — `NotificationService.init()`
  /// does that in `main()` before any widget builds.
  static DateTime? get eventStart {
    if (eventThursday.isEmpty) return null;
    try {
      final d = DateTime.parse(eventThursday);
      final central = tz.getLocation('America/Chicago');
      return tz.TZDateTime(central, d.year, d.month, d.day, 16);
    } catch (_) {
      return null;
    }
  }

  /// Venue name + city — fixed for the life of the con.
  static const String venueName = 'Alabama 4-H Center';
  static const String venueCityState = 'Columbiana, AL';

  /// Query string handed to the platform maps app — resolves to the venue
  /// without needing a hardcoded street address.
  static String get venueMapsQuery => '$venueName, $venueCityState';
}
