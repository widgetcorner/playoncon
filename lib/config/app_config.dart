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

  static const String discordInviteUrl =
      String.fromEnvironment('POC_DISCORD_INVITE_URL');

  static const String oneSignalAppId =
      String.fromEnvironment('POC_ONESIGNAL_APP_ID');

  /// Thursday of the convention, formatted yyyy-MM-dd.
  /// Used to anchor the grid-CSV schedule (which only carries day-of-week + time of day).
  static const String eventThursday =
      String.fromEnvironment('POC_EVENT_THURSDAY');

  static bool get hasScheduleUrl => scheduleCsvUrl.isNotEmpty;
  static bool get hasDiscordUrl => discordInviteUrl.isNotEmpty;
  static bool get hasOneSignalId => oneSignalAppId.isNotEmpty;
  static bool get hasEventThursday => eventThursday.isNotEmpty;
}
