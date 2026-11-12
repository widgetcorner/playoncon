// Simulator-only capture entry point. This is never a release build target.
// Build with scripts/capture-apple-store-assets.sh build. The production app,
// system Apple typography/emoji, native safe areas, and native Duo layout stream
// are retained; only the data and requested starting screen are controlled.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';
import 'package:path_provider/path_provider.dart';
import 'package:playoncon/app.dart';
import 'package:playoncon/app_navigation.dart';
import 'package:playoncon/config/app_config.dart';
import 'package:playoncon/features/map/venue_map_page.dart';
import 'package:playoncon/features/schedule/event_detail_page.dart';
import 'package:playoncon/features/schedule/schedule_page.dart';
import 'package:playoncon/models/cart_position.dart';
import 'package:playoncon/models/event.dart';
import 'package:playoncon/models/venue_location.dart';
import 'package:playoncon/services/app_clock.dart';
import 'package:playoncon/services/apple_layout.dart';
import 'package:playoncon/services/calibration_store.dart';
import 'package:playoncon/services/cart_positions_repository.dart';
import 'package:playoncon/services/last_tab_store.dart';
import 'package:playoncon/services/location_service.dart';
import 'package:playoncon/services/network_monitor.dart';
import 'package:playoncon/services/notification_service.dart';
import 'package:playoncon/services/saved_events_store.dart';
import 'package:playoncon/services/schedule_repository.dart';
import 'package:timezone/data/latest.dart' as tz_data;
import 'package:timezone/timezone.dart' as tz;

const _screens = {
  'all-sessions',
  'my-schedule',
  'event-detail',
  'venue-map',
  'info',
};

class _CaptureRepository extends ScheduleRepository {
  _CaptureRepository(super.ref, List<Event> events, DateTime syncedAt) {
    state = ScheduleState(events: events, lastSyncAt: syncedAt);
  }
  @override
  Future<void> bootstrap() async {}
  @override
  Future<void> refresh() async {}
}

// Implement the public store interface instead of calling SavedEventsStore's
// constructor: that constructor loads device files asynchronously and could
// replace the frozen bookmarks after the first frame on a real simulator.
class _CaptureSaves extends StateNotifier<Map<String, Reminder>>
    implements SavedEventsStore {
  _CaptureSaves(List<Event> events, List<String> titles)
    : super({
        for (final event in events.where((e) => titles.contains(e.title)))
          event.id: const Reminder.minutes(15),
      });

  @override
  bool isSaved(String id) => state.containsKey(id);
  @override
  Reminder reminderFor(String id) => state[id] ?? const Reminder.none();
  @override
  void save(String id, Reminder reminder) => state = {...state, id: reminder};
  @override
  void remove(String id) => state = {...state}..remove(id);
}

class _CaptureTab extends LastTabStore {
  _CaptureTab(super.initial);
  @override
  void set(int index) => state = index;
}

class _CaptureCalibration extends CalibrationStore {
  @override
  Future<List<CalibrationPoint>> load() async => const [];
}

class _CaptureGeolocator extends GeolocatorPlatform {
  @override
  Future<LocationPermission> checkPermission() async =>
      LocationPermission.denied;
  @override
  Future<LocationPermission> requestPermission() async =>
      LocationPermission.denied;
  @override
  Future<bool> isLocationServiceEnabled() async => false;
}

class _CaptureNotifications extends NotificationService {
  @override
  Future<void> init() async {}
  @override
  Future<bool> requestPermission() async => false;
  @override
  Future<void> schedule(Event event, Reminder reminder) async {}
  @override
  Future<void> cancel(String eventId) async {}
}

DateTime _central(DateTime date) => tz.TZDateTime(
  tz.getLocation('America/Chicago'),
  date.year,
  date.month,
  date.day,
  date.hour,
  date.minute,
  date.second,
);

Event _fixtureEvent(Map<String, dynamic> json) {
  final event = Event.fromJson(json);
  return Event(
    id: event.id,
    title: event.title,
    startTime: _central(event.startTime),
    endTime: _central(event.endTime),
    locationKey: event.locationKey,
    locationDisplayName: event.locationDisplayName,
    details: event.details,
    attributes: event.attributes,
    subSchedule: [
      for (final item in event.subSchedule)
        ScheduleItem(label: item.label, time: _central(item.time)),
    ],
  );
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (!Platform.isIOS || !kDebugMode) {
    throw StateError(
      'This entry point is only for debug Apple simulator captures.',
    );
  }
  final expectedConfig = jsonDecode(_captureConfigJson) as Map<String, dynamic>;
  final actualConfig = {
    'POC_EVENT_THURSDAY': AppConfig.eventThursday,
    'POC_SCHEDULE_VIEW_URL': AppConfig.scheduleViewUrl,
    'POC_DISCORD_INVITE_URL': AppConfig.discordInviteUrl,
    'POC_PROGRAM_URL': AppConfig.programUrl,
  };
  if (expectedConfig.entries.any((e) => actualConfig[e.key] != e.value) ||
      AppConfig.hasAppVersion ||
      AppConfig.hasScheduleSource ||
      AppConfig.hasSupabaseConfig ||
      AppConfig.calibrationEnabled) {
    throw StateError(
      'Use scripts/capture-apple-store-assets.sh build with frozen public '
      'screenshot configuration and no release credentials/defines.',
    );
  }
  final directory = await getApplicationDocumentsDirectory();
  final requestFile = File('${directory.path}/poc_capture_request.json');
  Map<String, dynamic>? request;
  if (await requestFile.exists()) {
    request =
        jsonDecode(await requestFile.readAsString()) as Map<String, dynamic>;
    if (request['screen'] is! String ||
        request['nonce'] is! String ||
        (request['nonce'] as String).isEmpty) {
      throw StateError('Capture request needs a screen and a nonempty nonce.');
    }
  }
  // iOS does not reliably expose launch environment variables to Dart. The
  // wrapper writes this request before launch; environment/defines are only a
  // fallback for manual diagnosis when the request file is absent.
  final screen =
      request?['screen'] as String? ??
      Platform.environment['POC_CAPTURE_SCREEN'] ??
      const String.fromEnvironment(
        'POC_CAPTURE_SCREEN',
        defaultValue: 'all-sessions',
      );
  final nonce =
      request?['nonce'] as String? ??
      Platform.environment['POC_CAPTURE_NONCE'] ??
      '';
  if (!_screens.contains(screen)) {
    throw StateError(
      'Unknown capture screen "$screen". Expected ${_screens.join(', ')}.',
    );
  }
  tz_data.initializeTimeZones();
  final scenario = jsonDecode(_captureScenarioJson) as Map<String, dynamic>;
  final events = (jsonDecode(_captureScheduleJson) as List)
      .cast<Map<String, dynamic>>()
      .map(_fixtureEvent)
      .toList();
  final locations =
      (jsonDecode(await rootBundle.loadString('assets/data/locations.json'))
              as List)
          .cast<Map<String, dynamic>>()
          .map(VenueLocation.fromJson)
          .toList();
  final savedTitles = (scenario['saved_titles'] as List).cast<String>();
  for (final title in savedTitles) {
    if (!events.any((event) => event.title == title)) {
      throw StateError(
        'Capture bookmark "$title" is missing from the fixture.',
      );
    }
  }
  final event = events.firstWhere((e) => e.title == scenario['detail_title']);
  final now = _central(DateTime.parse(scenario['now'] as String));
  final syncedAt = tz.TZDateTime(
    tz.getLocation('America/Chicago'),
    2026,
    7,
    2,
    15,
  );
  GeolocatorPlatform.instance = _CaptureGeolocator();

  runApp(
    ProviderScope(
      overrides: [
        scheduleRepositoryProvider.overrideWith(
          (ref) => _CaptureRepository(ref, events, syncedAt),
        ),
        savedEventsProvider.overrideWith(
          (_) => _CaptureSaves(events, savedTitles),
        ),
        selectedTabProvider.overrideWith(
          (_) => _CaptureTab(
            screen == 'info'
                ? 2
                : screen == 'venue-map'
                ? 1
                : 0,
          ),
        ),
        appClockProvider.overrideWithValue(() => now),
        connectivityProvider.overrideWith(
          (_) => Stream.value(const NetworkStatus(true)),
        ),
        venueLocationsProvider.overrideWith((_) async => locations),
        currentPositionProvider.overrideWith((_) => Stream.value(null)),
        cartPositionsProvider.overrideWith(
          (_) => Stream.value(const <String, CartPosition>{}),
        ),
        calibrationStoreProvider.overrideWithValue(_CaptureCalibration()),
        notificationServiceProvider.overrideWithValue(_CaptureNotifications()),
        mapDebugToolsProvider.overrideWithValue(false),
        // Deliberately do not override appleLayoutProvider. The native event
        // channel provides actual simulator/Duo geometry and bar preferences.
      ],
      child: _CaptureNavigation(screen: screen, nonce: nonce, event: event),
    ),
  );
}

class _CaptureNavigation extends ConsumerStatefulWidget {
  const _CaptureNavigation({
    required this.screen,
    required this.nonce,
    required this.event,
  });
  final String screen;
  final String nonce;
  final Event event;

  @override
  ConsumerState<_CaptureNavigation> createState() => _CaptureNavigationState();
}

class _CaptureNavigationState extends ConsumerState<_CaptureNavigation> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _navigate());
  }

  Element? _findElement(bool Function(Widget) matches) {
    Element? result;
    void visit(Element element) {
      if (result != null) return;
      if (matches(element.widget)) {
        result = element;
      } else {
        element.visitChildElements(visit);
      }
    }

    (context as Element).visitChildElements(visit);
    return result;
  }

  Future<void> _navigate() async {
    // Decode production artwork before declaring a screenshot ready.
    final shell = _findElement((widget) => widget is RootShell);
    if (shell == null) throw StateError('Production RootShell did not mount.');
    for (final asset in [
      'assets/branding/poc-logo.png',
      'assets/images/venue-map.png',
      'assets/images/venue-map-dark.png',
    ]) {
      await precacheImage(AssetImage(asset), shell);
    }
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted) return;

    switch (widget.screen) {
      case 'my-schedule':
        final tabs = _findElement((widget) => widget is TabBar);
        if (tabs == null) {
          throw StateError('Production schedule tabs did not mount.');
        }
        DefaultTabController.of(tabs).animateTo(1, duration: Duration.zero);
      case 'event-detail':
        final schedule = _findElement((widget) => widget is SchedulePage);
        if (schedule == null) {
          throw StateError('Production schedule did not mount.');
        }
        Navigator.of(schedule).push(
          MaterialPageRoute<void>(
            builder: (_) => EventDetailPage(event: widget.event),
          ),
        );
      case 'venue-map':
        final key = widget.event.locationKey;
        if (key == null) {
          throw StateError('Detail fixture has no map location.');
        }
        ref.showOnMap(key);
      case 'all-sessions':
      case 'info':
        break;
    }

    // Let production page/focus animations and the native Apple layout stream
    // settle. No geometry, insets, font families, or appearance are simulated.
    await Future<void>.delayed(const Duration(milliseconds: 900));
    WidgetsBinding.instance.scheduleFrame();
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted) return;
    final view = View.of(shell);
    final layout = await ref
        .read(appleLayoutProvider.future)
        .timeout(const Duration(seconds: 10));
    final directory = await getApplicationDocumentsDirectory();
    final marker = {
      'nonce': widget.nonce,
      'screen': widget.screen,
      'width': view.physicalSize.width.round(),
      'height': view.physicalSize.height.round(),
      'pixel_ratio': view.devicePixelRatio,
      'brightness': MediaQuery.platformBrightnessOf(shell).name,
      'apple_bar_edge': layout.barEdge.name,
      'apple_layout_size': {
        'width': layout.viewSize.width,
        'height': layout.viewSize.height,
      },
      'fixture_events': ref.read(scheduleRepositoryProvider).events.length,
    };
    await File(
      '${directory.path}/poc_capture_ready.json',
    ).writeAsString(jsonEncode(marker), flush: true);
    debugPrint('POC_CAPTURE_READY ${jsonEncode(marker)}');
  }

  @override
  Widget build(BuildContext context) => const PlayOnConApp();
}

// BEGIN FROZEN CAPTURE DATA
// Generated from the deliberate screenshot fixtures by the build wrapper.
const _captureScheduleJson = "[\n  {\n    \"id\": \"363185771_1783022400000_859746281\",\n    \"title\": \"Welcome Wagon\",\n    \"startTime\": \"2026-07-02T16:00:00.000\",\n    \"endTime\": \"2026-07-02T17:00:00.000\",\n    \"locationKey\": \"theater\",\n    \"locationDisplayName\": \"Theater\",\n    \"track\": null,\n    \"presenter\": null,\n    \"details\": \"Now to Play On Con? We've all been there! Come join a panel of Play On Con regulars as they share their advice for making the most of the weekend and answer your questions about what to expect.\",\n    \"attributes\": [],\n    \"subSchedule\": []\n  },\n  {\n    \"id\": \"227640236_1783026000000_882378525\",\n    \"title\": \"Make a Holiday Card\",\n    \"startTime\": \"2026-07-02T17:00:00.000\",\n    \"endTime\": \"2026-07-02T18:00:00.000\",\n    \"locationKey\": \"cafeteria\",\n    \"locationDisplayName\": \"Lodge\",\n    \"track\": null,\n    \"presenter\": null,\n    \"details\": \"Spread joy and encouragement this POC by joining our Apprentice Track Holiday Card Activity! Participants will create fun, handmade holiday cards filled with kind messages, drawings, and well wishes for whomever you want. All card-making supplies will be provided—just bring your creativity and a heart for encouraging others.\",\n    \"attributes\": [\n      \"AT\"\n    ],\n    \"subSchedule\": []\n  },\n  {\n    \"id\": \"578833199_1783026000000_590535442\",\n    \"title\": \"Kickoff Pool Party\",\n    \"startTime\": \"2026-07-02T17:00:00.000\",\n    \"endTime\": \"2026-07-02T18:00:00.000\",\n    \"locationKey\": \"pool\",\n    \"locationDisplayName\": \"Pool\",\n    \"track\": null,\n    \"presenter\": null,\n    \"details\": \"It's a pooltime paradise to start off the weekend! Come jump in the pool and enjoy good tunes!\",\n    \"attributes\": [],\n    \"subSchedule\": []\n  },\n  {\n    \"id\": \"65884514_1783029600000_433551012\",\n    \"title\": \"Ultimate Gamer Qualifiers (Runs till Saturday Start Time)\",\n    \"startTime\": \"2026-07-02T18:00:00.000\",\n    \"endTime\": \"2026-07-02T20:00:00.000\",\n    \"locationKey\": \"gaming\",\n    \"locationDisplayName\": \"Video Gaming\",\n    \"track\": null,\n    \"presenter\": null,\n    \"details\": null,\n    \"attributes\": [],\n    \"subSchedule\": []\n  },\n  {\n    \"id\": \"679169885_1783029600000_526582537\",\n    \"title\": \"Holiday Mixer - ALL AGES!!!\",\n    \"startTime\": \"2026-07-02T18:00:00.000\",\n    \"endTime\": \"2026-07-02T20:00:00.000\",\n    \"locationKey\": \"mayfield\",\n    \"locationDisplayName\": \"Lower Mayfield\",\n    \"track\": null,\n    \"presenter\": null,\n    \"details\": \"Kick off the convention by meeting new friends and reconnecting with familiar faces at our Holiday Mixer! Break the ice with fun getting-to-know-you games, take part in our optional \\\"Drinking Around the World\\\" challenge featuring holiday-inspired beverages (with plenty of alcohol-free options available), and share your favorite memories from PlayOnCons past. Whether it's your first year or you're a longtime camper, this is the perfect way to celebrate, laugh, and start the weekend together.\",\n    \"attributes\": [],\n    \"subSchedule\": []\n  },\n  {\n    \"id\": \"185235089_1783036800000_859746281\",\n    \"title\": \"Holiday TV Episodes\",\n    \"startTime\": \"2026-07-02T20:00:00.000\",\n    \"endTime\": \"2026-07-02T22:00:00.000\",\n    \"locationKey\": \"theater\",\n    \"locationDisplayName\": \"Theater\",\n    \"track\": null,\n    \"presenter\": null,\n    \"details\": \"We love a good holiday episode in our favorite TV shows! Come see some of our favorites and feel the joy of a special holiday episode!\",\n    \"attributes\": [],\n    \"subSchedule\": []\n  },\n  {\n    \"id\": \"262832465_1783036800000_433551012\",\n    \"title\": \"Nidhogg Tournament\",\n    \"startTime\": \"2026-07-02T20:00:00.000\",\n    \"endTime\": \"2026-07-02T22:00:00.000\",\n    \"locationKey\": \"gaming\",\n    \"locationDisplayName\": \"Video Gaming\",\n    \"track\": null,\n    \"presenter\": null,\n    \"details\": null,\n    \"attributes\": [],\n    \"subSchedule\": []\n  },\n  {\n    \"id\": \"333346069_1783036800000_982518793\",\n    \"title\": \"Magical Athletes\",\n    \"startTime\": \"2026-07-02T20:00:00.000\",\n    \"endTime\": \"2026-07-02T22:00:00.000\",\n    \"locationKey\": \"gaming\",\n    \"locationDisplayName\": \"Gaming\",\n    \"track\": null,\n    \"presenter\": null,\n    \"details\": null,\n    \"attributes\": [],\n    \"subSchedule\": [\n      {\n        \"label\": \"Learn To Play\",\n        \"time\": \"2026-07-02T20:00:00.000\"\n      },\n      {\n        \"label\": \"Tournament\",\n        \"time\": \"2026-07-02T20:30:00.000\"\n      }\n    ]\n  },\n  {\n    \"id\": \"1013670330_1783040400000_526582537\",\n    \"title\": \"Holiday Party\",\n    \"startTime\": \"2026-07-02T21:00:00.000\",\n    \"endTime\": \"2026-07-03T00:00:00.000\",\n    \"locationKey\": \"mayfield\",\n    \"locationDisplayName\": \"Lower Mayfield\",\n    \"track\": null,\n    \"presenter\": null,\n    \"details\": null,\n    \"attributes\": [\n      \"18+\"\n    ],\n    \"subSchedule\": []\n  },\n  {\n    \"id\": \"134604812_1783044000000_859746281\",\n    \"title\": \"Aegyo Theater\",\n    \"startTime\": \"2026-07-02T22:00:00.000\",\n    \"endTime\": \"2026-07-03T00:00:00.000\",\n    \"locationKey\": \"theater\",\n    \"locationDisplayName\": \"Theater\",\n    \"track\": null,\n    \"presenter\": null,\n    \"details\": null,\n    \"attributes\": [],\n    \"subSchedule\": []\n  },\n  {\n    \"id\": \"530947669_1783051200000_590535442\",\n    \"title\": \"Adult Swim\",\n    \"startTime\": \"2026-07-03T00:00:00.000\",\n    \"endTime\": \"2026-07-03T02:00:00.000\",\n    \"locationKey\": \"pool\",\n    \"locationDisplayName\": \"Pool\",\n    \"track\": null,\n    \"presenter\": null,\n    \"details\": null,\n    \"attributes\": [\n      \"21+\"\n    ],\n    \"subSchedule\": []\n  },\n  {\n    \"id\": \"551212887_1783051200000_526582537\",\n    \"title\": \"Dance...Heck\",\n    \"startTime\": \"2026-07-03T00:00:00.000\",\n    \"endTime\": \"2026-07-03T02:00:00.000\",\n    \"locationKey\": \"mayfield\",\n    \"locationDisplayName\": \"Lower Mayfield\",\n    \"track\": null,\n    \"presenter\": null,\n    \"details\": \"A dance party of a different sort. Join us for a set of weird tunes that will get you on your feet and out of your comfort zone. At last, you don't have to worry about being the worst dancer on the floor; just try not to be the second-worst. A reward awaits for those who survive the night!\",\n    \"attributes\": [\n      \"18+\"\n    ],\n    \"subSchedule\": []\n  },\n  {\n    \"id\": \"752161885_1783051200000_859746281\",\n    \"title\": \"Karaoke\",\n    \"startTime\": \"2026-07-03T00:00:00.000\",\n    \"endTime\": \"2026-07-03T02:00:00.000\",\n    \"locationKey\": \"theater\",\n    \"locationDisplayName\": \"Theater\",\n    \"track\": null,\n    \"presenter\": null,\n    \"details\": \"We will be featuring karaoke in various places around the show this year. We have it in the theater on Thursday Night, by the pool on Friday and Saturday, and some Adults Only Karoke in Lower Mayfield on Saturday night. Plus we have…\",\n    \"attributes\": [],\n    \"subSchedule\": []\n  },\n  {\n    \"id\": \"388856022_1783087200000_526582537\",\n    \"title\": \"Coffee Service\",\n    \"startTime\": \"2026-07-03T10:00:00.000\",\n    \"endTime\": \"2026-07-03T11:00:00.000\",\n    \"locationKey\": \"mayfield\",\n    \"locationDisplayName\": \"Lower Mayfield\",\n    \"track\": null,\n    \"presenter\": null,\n    \"details\": \"Your morning pick-me-up. Coffee with a variety of creamer and sweetener options will be available. A keurig is available if you'd like to bring your own special pods. 21+ may come inside Mayfield if you'd like some additions to your coffee.\",\n    \"attributes\": [\n      \"SF\"\n    ],\n    \"subSchedule\": []\n  },\n  {\n    \"id\": \"573977202_1783087200000_343892948\",\n    \"title\": \"Nature Run / Walk\",\n    \"startTime\": \"2026-07-03T10:00:00.000\",\n    \"endTime\": \"2026-07-03T11:00:00.000\",\n    \"locationKey\": \"picnic-tables\",\n    \"locationDisplayName\": \"Picnic Tables\",\n    \"track\": null,\n    \"presenter\": null,\n    \"details\": \"Start your day with a morning run or a leisurely walk. Runners can stick to the roads while the hikers hit the trails! What will we find? No bears, plz.\",\n    \"attributes\": [],\n    \"subSchedule\": []\n  },\n  {\n    \"id\": \"591090482_1783087200000_859746281\",\n    \"title\": \"Morning Cartoons\",\n    \"startTime\": \"2026-07-03T10:00:00.000\",\n    \"endTime\": \"2026-07-03T11:00:00.000\",\n    \"locationKey\": \"theater\",\n    \"locationDisplayName\": \"Theater\",\n    \"track\": null,\n    \"presenter\": null,\n    \"details\": \"Start your day off with the breakfast of champions… CARTOONS!\",\n    \"attributes\": [\n      \"SF\"\n    ],\n    \"subSchedule\": []\n  },\n  {\n    \"id\": \"71879916_1783087200000_433551012\",\n    \"title\": \"Holiday Just Dance\",\n    \"startTime\": \"2026-07-03T10:00:00.000\",\n    \"endTime\": \"2026-07-03T11:00:00.000\",\n    \"locationKey\": \"gaming\",\n    \"locationDisplayName\": \"Video Gaming\",\n    \"track\": null,\n    \"presenter\": null,\n    \"details\": null,\n    \"attributes\": [],\n    \"subSchedule\": []\n  },\n  {\n    \"id\": \"293732003_1783090800000_882378525\",\n    \"title\": \"Perler Bead Crafts\",\n    \"startTime\": \"2026-07-03T11:00:00.000\",\n    \"endTime\": \"2026-07-03T12:00:00.000\",\n    \"locationKey\": \"cafeteria\",\n    \"locationDisplayName\": \"Lodge\",\n    \"track\": null,\n    \"presenter\": null,\n    \"details\": \"Perler beads are small, colorful plastic beads that can be arranged on a pegboard and fused together with heat to create permanent designs. Come make your own creations with us!\",\n    \"attributes\": [],\n    \"subSchedule\": []\n  },\n  {\n    \"id\": \"455546509_1783090800000_859746281\",\n    \"title\": \"Buzzer Trivia\",\n    \"startTime\": \"2026-07-03T11:00:00.000\",\n    \"endTime\": \"2026-07-03T12:00:00.000\",\n    \"locationKey\": \"theater\",\n    \"locationDisplayName\": \"Theater\",\n    \"track\": null,\n    \"presenter\": null,\n    \"details\": null,\n    \"attributes\": [],\n    \"subSchedule\": []\n  },\n  {\n    \"id\": \"571445307_1783090800000_982518793\",\n    \"title\": \"Learn to Play: Riftbound\",\n    \"startTime\": \"2026-07-03T11:00:00.000\",\n    \"endTime\": \"2026-07-03T12:00:00.000\",\n    \"locationKey\": \"gaming\",\n    \"locationDisplayName\": \"Gaming\",\n    \"track\": null,\n    \"presenter\": null,\n    \"details\": \"Riftbound is an official collectible trading card game developed by Riot Games, set in the League of Legends universe. Players command armies of iconic champions, cast spells, and use gear to conquer and hold battlefields in a race to earn 8 points and win the game.\",\n    \"attributes\": [],\n    \"subSchedule\": []\n  },\n  {\n    \"id\": \"794613506_1783090800000_526582537\",\n    \"title\": \"Build Your Own Bloody Mary\",\n    \"startTime\": \"2026-07-03T11:00:00.000\",\n    \"endTime\": \"2026-07-03T12:00:00.000\",\n    \"locationKey\": \"mayfield\",\n    \"locationDisplayName\": \"Lower Mayfield\",\n    \"track\": null,\n    \"presenter\": null,\n    \"details\": \"All the spices and fixin's you could ask for! Come make your own Bloody Mary with or without advice from your host Casey.\",\n    \"attributes\": [\n      \"21+\"\n    ],\n    \"subSchedule\": []\n  },\n  {\n    \"id\": \"896691377_1783090800000_433551012\",\n    \"title\": \"Super Smash Brothers Ultimate Singles\",\n    \"startTime\": \"2026-07-03T11:00:00.000\",\n    \"endTime\": \"2026-07-03T14:00:00.000\",\n    \"locationKey\": \"gaming\",\n    \"locationDisplayName\": \"Video Gaming\",\n    \"track\": null,\n    \"presenter\": null,\n    \"details\": null,\n    \"attributes\": [],\n    \"subSchedule\": []\n  },\n  {\n    \"id\": \"110456808_1783094400000_982518793\",\n    \"title\": \"Magic The Gathering : Jumpstart\",\n    \"startTime\": \"2026-07-03T12:00:00.000\",\n    \"endTime\": \"2026-07-03T15:00:00.000\",\n    \"locationKey\": \"gaming\",\n    \"locationDisplayName\": \"Gaming\",\n    \"track\": null,\n    \"presenter\": null,\n    \"details\": \"Drop in and jam! 2 provided packs and another player is all you need to play! This event will be open to players of all skill levels, and help provided for beginners with no time commitment necessary.\",\n    \"attributes\": [],\n    \"subSchedule\": []\n  },\n  {\n    \"id\": \"332919785_1783094400000_859746281\",\n    \"title\": \"Karaoke Battles\",\n    \"startTime\": \"2026-07-03T12:00:00.000\",\n    \"endTime\": \"2026-07-03T13:00:00.000\",\n    \"locationKey\": \"theater\",\n    \"locationDisplayName\": \"Theater\",\n    \"track\": null,\n    \"presenter\": null,\n    \"details\": null,\n    \"attributes\": [],\n    \"subSchedule\": []\n  },\n  {\n    \"id\": \"410153045_1783094400000_882378525\",\n    \"title\": \"How To: Tie-Dye\",\n    \"startTime\": \"2026-07-03T12:00:00.000\",\n    \"endTime\": \"2026-07-03T13:00:00.000\",\n    \"locationKey\": \"cafeteria\",\n    \"locationDisplayName\": \"Lodge\",\n    \"track\": null,\n    \"presenter\": null,\n    \"details\": \"Tie Dye is a great way to make custom clothing without breaking the bank. Learn how to turn fabric into a testament to love and peace! This event includes our Apprentices. BYOT, but a few shirts will be available at the event.\",\n    \"attributes\": [\n      \"AT\"\n    ],\n    \"subSchedule\": []\n  },\n  {\n    \"id\": \"983470058_1783094400000_343892948\",\n    \"title\": \"Boat On!\",\n    \"startTime\": \"2026-07-03T12:00:00.000\",\n    \"endTime\": \"2026-07-03T14:00:00.000\",\n    \"locationKey\": \"dock-canoes\",\n    \"locationDisplayName\": \"Dock & Canoes\",\n    \"track\": null,\n    \"presenter\": null,\n    \"details\": \"Take a leisurely trip afloat on Lay Lake. Pick from Canoes, Kayaks and Paddleboards! Canoeing sessions are limited to 30 people.\",\n    \"attributes\": [],\n    \"subSchedule\": []\n  },\n  {\n    \"id\": \"269563372_1783098000000_859746281\",\n    \"title\": \"Jackbox Party! (WIFI Permitting)\",\n    \"startTime\": \"2026-07-03T13:00:00.000\",\n    \"endTime\": \"2026-07-03T14:00:00.000\",\n    \"locationKey\": \"theater\",\n    \"locationDisplayName\": \"Theater\",\n    \"track\": null,\n    \"presenter\": null,\n    \"details\": \"Join us for some Jackbox Party games in the Theater! We're going to experiment whether the wifi can support it! Bring a tablet or phone!\",\n    \"attributes\": [],\n    \"subSchedule\": []\n  },\n  {\n    \"id\": \"4108637_1783098000000_882378525\",\n    \"title\": \"Valentines Speed Meeting (Make new Friends)\",\n    \"startTime\": \"2026-07-03T13:00:00.000\",\n    \"endTime\": \"2026-07-03T14:00:00.000\",\n    \"locationKey\": \"cafeteria\",\n    \"locationDisplayName\": \"Lodge\",\n    \"track\": null,\n    \"presenter\": null,\n    \"details\": null,\n    \"attributes\": [],\n    \"subSchedule\": []\n  },\n  {\n    \"id\": \"49344691_1783098000000_526582537\",\n    \"title\": \"Egg Nog Class & Tasting\",\n    \"startTime\": \"2026-07-03T13:00:00.000\",\n    \"endTime\": \"2026-07-03T14:00:00.000\",\n    \"locationKey\": \"mayfield\",\n    \"locationDisplayName\": \"Lower Mayfield\",\n    \"track\": null,\n    \"presenter\": null,\n    \"details\": \"Join the Reverend for a class on how to make boozy egg nog from scratch…and age it. Participants will sample a fresh preparation plus one aged for a month, and a third aged with extra prep before presentation. Perfect for a hot summer day!\",\n    \"attributes\": [\n      \"21+\"\n    ],\n    \"subSchedule\": []\n  },\n  {\n    \"id\": \"166259882_1783101600000_859746281\",\n    \"title\": \"Leveling Up: Kids, Games, and Growing Minds\",\n    \"startTime\": \"2026-07-03T14:00:00.000\",\n    \"endTime\": \"2026-07-03T15:00:00.000\",\n    \"locationKey\": \"theater\",\n    \"locationDisplayName\": \"Theater\",\n    \"track\": null,\n    \"presenter\": null,\n    \"details\": \"Join therapist Christine Penguino, LCSW, and Dr. Sandy Whetmore, PhD in Early Childhood Education, for a discussion on the positive impact of gaming on children's development. From tabletop adventures to video games, we'll explore how games can build creativity, problem-solving, emotional resilience, social connection, and family bonding. Whether you're a parent, educator, gamer, or just curious about why kids love rolling dice and pressing start, this panel will separate the \\\"screen time goblins\\\" from the real-world benefits hiding in the treasure chest.\",\n    \"attributes\": [\n      \"SF\"\n    ],\n    \"subSchedule\": []\n  },\n  {\n    \"id\": \"521158796_1783101600000_526582537\",\n    \"title\": \"Cabaret 101\",\n    \"startTime\": \"2026-07-03T14:00:00.000\",\n    \"endTime\": \"2026-07-03T15:00:00.000\",\n    \"locationKey\": \"mayfield\",\n    \"locationDisplayName\": \"Lower Mayfield\",\n    \"track\": null,\n    \"presenter\": null,\n    \"details\": \"Join in on some cabaret dance basics with a holiday twist! Dance shoes or socks are encouraged, but barefoot is fine, too!\",\n    \"attributes\": [\n      \"21+\"\n    ],\n    \"subSchedule\": []\n  },\n  {\n    \"id\": \"799226954_1783101600000_343892948\",\n    \"title\": \"Archery\",\n    \"startTime\": \"2026-07-03T14:00:00.000\",\n    \"endTime\": \"2026-07-03T18:00:00.000\",\n    \"locationKey\": \"archery\",\n    \"locationDisplayName\": \"Archery Field\",\n    \"track\": null,\n    \"presenter\": null,\n    \"details\": \"Whether you imagine yourself as Robin Hood or Hawkeye, you owe yourself a chance to see how you stack up!\",\n    \"attributes\": [],\n    \"subSchedule\": []\n  },\n  {\n    \"id\": \"825740487_1783101600000_590535442\",\n    \"title\": \"Poolside Party Karaoke\",\n    \"startTime\": \"2026-07-03T14:00:00.000\",\n    \"endTime\": \"2026-07-03T16:00:00.000\",\n    \"locationKey\": \"pool\",\n    \"locationDisplayName\": \"Pool\",\n    \"track\": null,\n    \"presenter\": null,\n    \"details\": null,\n    \"attributes\": [],\n    \"subSchedule\": []\n  },\n  {\n    \"id\": \"890208359_1783101600000_433551012\",\n    \"title\": \"Tetris\",\n    \"startTime\": \"2026-07-03T14:00:00.000\",\n    \"endTime\": \"2026-07-03T17:00:00.000\",\n    \"locationKey\": \"gaming\",\n    \"locationDisplayName\": \"Video Gaming\",\n    \"track\": null,\n    \"presenter\": null,\n    \"details\": null,\n    \"attributes\": [],\n    \"subSchedule\": []\n  },\n  {\n    \"id\": \"144982832_1783105200000_859746281\",\n    \"title\": \"Star Wars Trivia (Holiday Special and more!)\",\n    \"startTime\": \"2026-07-03T15:00:00.000\",\n    \"endTime\": \"2026-07-03T16:00:00.000\",\n    \"locationKey\": \"theater\",\n    \"locationDisplayName\": \"Theater\",\n    \"track\": null,\n    \"presenter\": null,\n    \"details\": \"Come join host Tony Black (aka Ohio Tony) for Star Wars (Holiday Special and more) Trivia! Compete in teams or individually to win a fabulous prize. Plus, there will be inflatable lightsabers! Be warned, this will not be easy.\",\n    \"attributes\": [],\n    \"subSchedule\": []\n  },\n  {\n    \"id\": \"301805501_1783105200000_343892948\",\n    \"title\": \"Cooler Yacht-Zee\",\n    \"startTime\": \"2026-07-03T15:00:00.000\",\n    \"endTime\": \"2026-07-03T16:00:00.000\",\n    \"locationKey\": \"recreation-field\",\n    \"locationDisplayName\": \"Rec Field\",\n    \"track\": null,\n    \"presenter\": null,\n    \"details\": \"We have two sets of large outdoor dice and have a drinking game of Yahtzee (or 2) with them! We will bring a cooler of drinks and you can also byob. Ideally right after beer croquet.\",\n    \"attributes\": [\n      \"21+\"\n    ],\n    \"subSchedule\": []\n  },\n  {\n    \"id\": \"388534916_1783105200000_982518793\",\n    \"title\": \"Looot!\",\n    \"startTime\": \"2026-07-03T15:00:00.000\",\n    \"endTime\": \"2026-07-03T17:00:00.000\",\n    \"locationKey\": \"gaming\",\n    \"locationDisplayName\": \"Gaming\",\n    \"track\": null,\n    \"presenter\": null,\n    \"details\": null,\n    \"attributes\": [],\n    \"subSchedule\": [\n      {\n        \"label\": \"Learn to Play\",\n        \"time\": \"2026-07-03T15:00:00.000\"\n      },\n      {\n        \"label\": \"Tournament\",\n        \"time\": \"2026-07-03T15:30:00.000\"\n      }\n    ]\n  },\n  {\n    \"id\": \"609539421_1783105200000_882378525\",\n    \"title\": \"Jam Session\",\n    \"startTime\": \"2026-07-03T15:00:00.000\",\n    \"endTime\": \"2026-07-03T17:00:00.000\",\n    \"locationKey\": \"cafeteria\",\n    \"locationDisplayName\": \"Lodge\",\n    \"track\": null,\n    \"presenter\": null,\n    \"details\": \"Join in an open jam in the Guthrie Lodge. We have a wide variety of instruments that might be stopping in, including ukuleles, guitars, flutes, and even a hurdy gurdy! Be sure to bring some water. All skill levels are welcome to jam out some tunes! Feel free to come sing, clap, or shake a shaker.\",\n    \"attributes\": [],\n    \"subSchedule\": []\n  },\n  {\n    \"id\": \"698806821_1783105200000_526582537\",\n    \"title\": \"Open Cantina\",\n    \"startTime\": \"2026-07-03T15:00:00.000\",\n    \"endTime\": \"2026-07-03T19:00:00.000\",\n    \"locationKey\": \"mayfield\",\n    \"locationDisplayName\": \"Lower Mayfield\",\n    \"track\": null,\n    \"presenter\": null,\n    \"details\": \"Come chill out in Lower Mayfield with us! We'll be serving and have the area open for people to relax. There maybe classes going on as well.\",\n    \"attributes\": [\n      \"18+\"\n    ],\n    \"subSchedule\": []\n  },\n  {\n    \"id\": \"195464950_1783108800000_859746281\",\n    \"title\": \"Malevolent Karaoke\",\n    \"startTime\": \"2026-07-03T16:00:00.000\",\n    \"endTime\": \"2026-07-03T18:00:00.000\",\n    \"locationKey\": \"theater\",\n    \"locationDisplayName\": \"Theater\",\n    \"track\": null,\n    \"presenter\": null,\n    \"details\": \"Make your loved ones and friends sing songs they hate for fun and fabulous prizes! Two-person teams are required, and you'll score higher if your partner really knows which songs make you squirm. We'll pair up any single players, though, so feel free to come alone! Judges will assign scores in Malevolence, Performance, and Audience Reaction.\",\n    \"attributes\": [\n      \"PG13\"\n    ],\n    \"subSchedule\": []\n  },\n  {\n    \"id\": \"586354274_1783108800000_343892948\",\n    \"title\": \"Beer Croquet\",\n    \"startTime\": \"2026-07-03T16:00:00.000\",\n    \"endTime\": \"2026-07-03T18:00:00.000\",\n    \"locationKey\": \"recreation-field\",\n    \"locationDisplayName\": \"Rec Field\",\n    \"track\": null,\n    \"presenter\": null,\n    \"details\": \"Join The Reverend for a round of BYOB croquet! One hand MUST be distracted with a beverage to play. Seersucker suits are appropriate. 21+ Only!\",\n    \"attributes\": [\n      \"21+\"\n    ],\n    \"subSchedule\": []\n  },\n  {\n    \"id\": \"505102961_1783112400000_982518793\",\n    \"title\": \"Ticket to Ride: First Journey (US) Learn to Play (Treehouse)\",\n    \"startTime\": \"2026-07-03T17:00:00.000\",\n    \"endTime\": \"2026-07-03T18:00:00.000\",\n    \"locationKey\": \"gaming\",\n    \"locationDisplayName\": \"Gaming\",\n    \"track\": null,\n    \"presenter\": null,\n    \"details\": null,\n    \"attributes\": [],\n    \"subSchedule\": []\n  },\n  {\n    \"id\": \"832899095_1783112400000_982518793\",\n    \"title\": \"Goblin Quest TTRPG\",\n    \"startTime\": \"2026-07-03T17:00:00.000\",\n    \"endTime\": \"2026-07-03T20:00:00.000\",\n    \"locationKey\": \"gaming\",\n    \"locationDisplayName\": \"Gaming\",\n    \"track\": null,\n    \"presenter\": null,\n    \"details\": \"Goblin Quest is a tabletop roleplaying game about slapstick violence, fatal ineptitude, and the greatest adventure of your life. Play five goblins each (in sequence, not parallel) and watch them meet hilarious ends while failing to achieve the most basic tasks. Will they survive the dangerous world of the Great Battle Camp and avoid the attentions of brutal orcs, murderous bugbears, mean-spirited hobgoblins and scary wizards? Probably not. But you'll have fun finding out! Ages 12+.\",\n    \"attributes\": [\n      \"PG13\"\n    ],\n    \"subSchedule\": []\n  },\n  {\n    \"id\": \"568515132_1783116000000_982518793\",\n    \"title\": \"Catan Junior Learn and Play (Treehouse)\",\n    \"startTime\": \"2026-07-03T18:00:00.000\",\n    \"endTime\": \"2026-07-03T19:00:00.000\",\n    \"locationKey\": \"gaming\",\n    \"locationDisplayName\": \"Gaming\",\n    \"track\": null,\n    \"presenter\": null,\n    \"details\": null,\n    \"attributes\": [],\n    \"subSchedule\": []\n  },\n  {\n    \"id\": \"815945815_1783116000000_343892948\",\n    \"title\": \"Presidential Nominations & Table Flipping\",\n    \"startTime\": \"2026-07-03T18:00:00.000\",\n    \"endTime\": \"2026-07-03T19:00:00.000\",\n    \"locationKey\": \"picnic-tables\",\n    \"locationDisplayName\": \"Canopy\",\n    \"track\": null,\n    \"presenter\": null,\n    \"details\": null,\n    \"attributes\": [],\n    \"subSchedule\": []\n  },\n  {\n    \"id\": \"145693448_1783119600000_526582537\",\n    \"title\": \"Cantina Counter Service\",\n    \"startTime\": \"2026-07-03T19:00:00.000\",\n    \"endTime\": \"2026-07-03T21:00:00.000\",\n    \"locationKey\": \"mayfield\",\n    \"locationDisplayName\": \"Lower Mayfield\",\n    \"track\": null,\n    \"presenter\": null,\n    \"details\": \"We'll be serving so you can have some refreshments while enjoying the other events!\",\n    \"attributes\": [\n      \"21+\"\n    ],\n    \"subSchedule\": []\n  },\n  {\n    \"id\": \"331832031_1783119600000_343892948\",\n    \"title\": \"Sparkling Noise\",\n    \"startTime\": \"2026-07-03T19:00:00.000\",\n    \"endTime\": \"2026-07-03T20:00:00.000\",\n    \"locationKey\": \"picnic-tables\",\n    \"locationDisplayName\": \"Canopy\",\n    \"track\": null,\n    \"presenter\": null,\n    \"details\": null,\n    \"attributes\": [],\n    \"subSchedule\": []\n  },\n  {\n    \"id\": \"732637586_1783119600000_882378525\",\n    \"title\": \"Apprentice Party\",\n    \"startTime\": \"2026-07-03T19:00:00.000\",\n    \"endTime\": \"2026-07-03T22:00:00.000\",\n    \"locationKey\": \"morrison-dorm\",\n    \"locationDisplayName\": \"Lower Morrison Dorm\",\n    \"track\": null,\n    \"presenter\": null,\n    \"details\": null,\n    \"attributes\": [\n      \"AT\"\n    ],\n    \"subSchedule\": []\n  },\n  {\n    \"id\": \"492617978_1783123200000_982518793\",\n    \"title\": \"Times Past TTRPG\",\n    \"startTime\": \"2026-07-03T20:00:00.000\",\n    \"endTime\": \"2026-07-03T23:00:00.000\",\n    \"locationKey\": \"gaming\",\n    \"locationDisplayName\": \"Gaming\",\n    \"track\": null,\n    \"presenter\": null,\n    \"details\": \"You wake up in the barracks just like every day (right?). You meet the eyes of your companions and say your good mornings as you always do (right?), but this time as you do you catch a flash of a memory of a feeling of fear, betrayal, confusion, and war. It ends almost before it begins, but it's still there in the back of your mind. You expect this day to be just like \\\"every other day\\\" as always just as you \\\"remember\\\" them being, except this morning a man runs in panicking and says \\\"The village is under attack by monsters!\\\" (Which never happens, right?). What happens next is up to you. Interested? Come play and find out where the group will take the story next! Ages 12+.\",\n    \"attributes\": [\n      \"PG13\"\n    ],\n    \"subSchedule\": []\n  },\n  {\n    \"id\": \"989259726_1783123200000_343892948\",\n    \"title\": \"Music: Professor Shyguy\",\n    \"startTime\": \"2026-07-03T20:00:00.000\",\n    \"endTime\": \"2026-07-03T21:00:00.000\",\n    \"locationKey\": \"picnic-tables\",\n    \"locationDisplayName\": \"Canopy\",\n    \"track\": null,\n    \"presenter\": null,\n    \"details\": \"Come join Professor Shyguy for a flurry of chiptune rock. With his anthems to everything from The Guild to Portal, this show is destined to appeal to all your nerdy bits.\",\n    \"attributes\": [],\n    \"subSchedule\": []\n  },\n  {\n    \"id\": \"39676251_1783126800000_433551012\",\n    \"title\": \"Electoral Carnage\",\n    \"startTime\": \"2026-07-03T21:00:00.000\",\n    \"endTime\": \"2026-07-03T23:00:00.000\",\n    \"locationKey\": \"gaming\",\n    \"locationDisplayName\": \"Video Gaming\",\n    \"track\": null,\n    \"presenter\": null,\n    \"details\": null,\n    \"attributes\": [],\n    \"subSchedule\": []\n  },\n  {\n    \"id\": \"515563017_1783126800000_526582537\",\n    \"title\": \"Old School Anime Party\",\n    \"startTime\": \"2026-07-03T21:00:00.000\",\n    \"endTime\": \"2026-07-04T01:00:00.000\",\n    \"locationKey\": \"mayfield\",\n    \"locationDisplayName\": \"Lower Mayfield\",\n    \"track\": null,\n    \"presenter\": null,\n    \"details\": null,\n    \"attributes\": [\n      \"18+\"\n    ],\n    \"subSchedule\": []\n  },\n  {\n    \"id\": \"578083806_1783130400000_343892948\",\n    \"title\": \"Yule Fire\",\n    \"startTime\": \"2026-07-03T22:00:00.000\",\n    \"endTime\": \"2026-07-04T00:00:00.000\",\n    \"locationKey\": \"lakeview-fire-pit\",\n    \"locationDisplayName\": \"Lakeside Fire Pit\",\n    \"track\": null,\n    \"presenter\": null,\n    \"details\": \"Tis the Season to relax by the fire! Come join us as we bask in some warm flames and warm hearts.\",\n    \"attributes\": [\n      \"SF\"\n    ],\n    \"subSchedule\": []\n  },\n  {\n    \"id\": \"636429448_1783130400000_859746281\",\n    \"title\": \"Star Wars: Holiday Special\",\n    \"startTime\": \"2026-07-03T22:00:00.000\",\n    \"endTime\": \"2026-07-03T23:00:00.000\",\n    \"locationKey\": \"theater\",\n    \"locationDisplayName\": \"Theater\",\n    \"track\": null,\n    \"presenter\": null,\n    \"details\": \"Look. We know it's bad. It's REALLY bad. But is it so bad it's good? Probably not. Still, it was a major inspiration for this year's theme, so we ALL get to experience it!\\n\\nWe're sorry…. maybe.\",\n    \"attributes\": [],\n    \"subSchedule\": []\n  },\n  {\n    \"id\": \"980804450_1783134000000_982518793\",\n    \"title\": \"Blood on the Clocktower\",\n    \"startTime\": \"2026-07-03T23:00:00.000\",\n    \"endTime\": \"2026-07-04T01:00:00.000\",\n    \"locationKey\": \"gaming\",\n    \"locationDisplayName\": \"Gaming\",\n    \"track\": null,\n    \"presenter\": null,\n    \"details\": \"A scream echoes through the sleepy town of Ravenswood Bluff. The townsfolk rush to investigate and find the beloved local storyteller has been murdered, their body hanging limp from the clocktower. As blood drips onto the cobblestones below, a realization slowly dawns… a demon has been unleashed, killing by night and taking on human form by day. Can good find the demon in time? Or will evil overrun this once peaceful town?\\n\\nBlood on the Clocktower is a game of murder and mystery, lies and logic, deduction and deception for five-to-twenty courageous players and one devious storyteller.\\n\\nA social game played in person, seated in a circle, each player receives either a 'good' or 'evil' token with their unique character on it. Good players share information to solve the mystery whilst evil players lie about who they are and what they know. The good team wins if they can piece together their knowledge, trust each other, and execute the demon. The evil team wins if the demon can sow distrust, evade detection, and wipe out the village.\",\n    \"attributes\": [],\n    \"subSchedule\": []\n  },\n  {\n    \"id\": \"73521533_1783135800000_859746281\",\n    \"title\": \"Rocky Horror Picture Show\",\n    \"startTime\": \"2026-07-03T23:30:00.000\",\n    \"endTime\": \"2026-07-04T01:00:00.000\",\n    \"locationKey\": \"theater\",\n    \"locationDisplayName\": \"Theater\",\n    \"track\": null,\n    \"presenter\": null,\n    \"details\": \"The Rocky Horror Picture Show with audience partici...pation! Costumes and props are encouraged, though we'll restrict anything that's messy (so no food or anything that can't be cleaned up within a couple of minutes). We'll have a quick 5-10 minute intro at the beginning, then show the movie.\",\n    \"attributes\": [\n      \"PG13\"\n    ],\n    \"subSchedule\": []\n  },\n  {\n    \"id\": \"530947669_1783137600000_590535442\",\n    \"title\": \"Adult Swim\",\n    \"startTime\": \"2026-07-04T00:00:00.000\",\n    \"endTime\": \"2026-07-04T02:00:00.000\",\n    \"locationKey\": \"pool\",\n    \"locationDisplayName\": \"Pool\",\n    \"track\": null,\n    \"presenter\": null,\n    \"details\": null,\n    \"attributes\": [\n      \"21+\"\n    ],\n    \"subSchedule\": []\n  },\n  {\n    \"id\": \"299355418_1783173600000_433551012\",\n    \"title\": \"Ultimate Gamer\",\n    \"startTime\": \"2026-07-04T10:00:00.000\",\n    \"endTime\": \"2026-07-04T14:00:00.000\",\n    \"locationKey\": \"gaming\",\n    \"locationDisplayName\": \"Video Gaming\",\n    \"track\": null,\n    \"presenter\": null,\n    \"details\": \"Back after a multi year break, it's the con tradition of The Ultimate Gamer. Once a weekend long gauntlet, now place your score on the tryout game in Video Gaming before Saturday morning and then show up and compete in an 8 person winner take all battle for the ultimate crown (crown included)!\\n\\nIf there's more room for ham: Prove to your friends and family that you are indeed the Ultimate Gamer, at least for this year. Guaranteed to finish in less than the entire weekend!\",\n    \"attributes\": [],\n    \"subSchedule\": []\n  },\n  {\n    \"id\": \"371576460_1783173600000_433551012\",\n    \"title\": \"Just Dance\",\n    \"startTime\": \"2026-07-04T10:00:00.000\",\n    \"endTime\": \"2026-07-04T11:00:00.000\",\n    \"locationKey\": \"gaming\",\n    \"locationDisplayName\": \"Video Gaming\",\n    \"track\": null,\n    \"presenter\": null,\n    \"details\": \"Start your morning with song and dance! A hearty round of energetic expression… on a dance pad. Friday's session will be for everyone, and Saturday will host an Apprentice session! Touching grass is overrated!\",\n    \"attributes\": [\n      \"AT\"\n    ],\n    \"subSchedule\": []\n  },\n  {\n    \"id\": \"388856022_1783173600000_526582537\",\n    \"title\": \"Coffee Service\",\n    \"startTime\": \"2026-07-04T10:00:00.000\",\n    \"endTime\": \"2026-07-04T11:00:00.000\",\n    \"locationKey\": \"mayfield\",\n    \"locationDisplayName\": \"Lower Mayfield\",\n    \"track\": null,\n    \"presenter\": null,\n    \"details\": \"Your morning pick-me-up. Coffee with a variety of creamer and sweetener options will be available. A keurig is available if you'd like to bring your own special pods. 21+ may come inside Mayfield if you'd like some additions to your coffee.\",\n    \"attributes\": [\n      \"SF\"\n    ],\n    \"subSchedule\": []\n  },\n  {\n    \"id\": \"573977202_1783173600000_343892948\",\n    \"title\": \"Nature Run / Walk\",\n    \"startTime\": \"2026-07-04T10:00:00.000\",\n    \"endTime\": \"2026-07-04T11:00:00.000\",\n    \"locationKey\": \"picnic-tables\",\n    \"locationDisplayName\": \"Picnic Tables\",\n    \"track\": null,\n    \"presenter\": null,\n    \"details\": \"Start your day with a morning run or a leisurely walk. Runners can stick to the roads while the hikers hit the trails! What will we find? No bears, plz.\",\n    \"attributes\": [],\n    \"subSchedule\": []\n  },\n  {\n    \"id\": \"591090482_1783173600000_859746281\",\n    \"title\": \"Morning Cartoons\",\n    \"startTime\": \"2026-07-04T10:00:00.000\",\n    \"endTime\": \"2026-07-04T11:00:00.000\",\n    \"locationKey\": \"theater\",\n    \"locationDisplayName\": \"Theater\",\n    \"track\": null,\n    \"presenter\": null,\n    \"details\": \"Start your day off with the breakfast of champions… CARTOONS!\",\n    \"attributes\": [\n      \"SF\"\n    ],\n    \"subSchedule\": []\n  },\n  {\n    \"id\": \"695925387_1783173600000_882378525\",\n    \"title\": \"Crochet Craft Session\",\n    \"startTime\": \"2026-07-04T10:00:00.000\",\n    \"endTime\": \"2026-07-04T12:00:00.000\",\n    \"locationKey\": \"cafeteria\",\n    \"locationDisplayName\": \"Lodge\",\n    \"track\": null,\n    \"presenter\": null,\n    \"details\": \"Choose from four fun creations to celebrate your favorite holiday or just your nerdiness! Hillary will guide you through creating a cute amigurumi project that's easy for beginners and fun for more experienced crafters as well. Any skill level is welcome and all materials will be provided.\",\n    \"attributes\": [],\n    \"subSchedule\": []\n  },\n  {\n    \"id\": \"141827970_1783177200000_343892948\",\n    \"title\": \"Easter Egg Hunt\",\n    \"startTime\": \"2026-07-04T11:00:00.000\",\n    \"endTime\": \"2026-07-04T12:00:00.000\",\n    \"locationKey\": \"mini-golf\",\n    \"locationDisplayName\": \"Mini-golf\",\n    \"track\": null,\n    \"presenter\": null,\n    \"details\": \"Get ready for a fun-filled Easter adventure designed especially for our Apprentice Track participants! Join us at the miniature golf course for an exciting Easter Egg Hunt where you'll search for colorful eggs hidden throughout the course, enjoy the festive atmosphere, and connect with friends along the way.\\n\\nBring your Easter basket, wear comfortable shoes, and get ready for a time of laughter, teamwork, and friendly competition. Keep an eye out for special prize eggs hidden among the course—they could lead to extra surprises!\",\n    \"attributes\": [\n      \"AT\"\n    ],\n    \"subSchedule\": []\n  },\n  {\n    \"id\": \"42755022_1783177200000_982518793\",\n    \"title\": \"Parsely Live Text Adventure\",\n    \"startTime\": \"2026-07-04T11:00:00.000\",\n    \"endTime\": \"2026-07-04T13:00:00.000\",\n    \"locationKey\": \"gaming\",\n    \"locationDisplayName\": \"Gaming\",\n    \"track\": null,\n    \"presenter\": null,\n    \"details\": null,\n    \"attributes\": [],\n    \"subSchedule\": []\n  },\n  {\n    \"id\": \"455546509_1783177200000_859746281\",\n    \"title\": \"Buzzer Trivia\",\n    \"startTime\": \"2026-07-04T11:00:00.000\",\n    \"endTime\": \"2026-07-04T12:00:00.000\",\n    \"locationKey\": \"theater\",\n    \"locationDisplayName\": \"Theater\",\n    \"track\": null,\n    \"presenter\": null,\n    \"details\": null,\n    \"attributes\": [],\n    \"subSchedule\": []\n  },\n  {\n    \"id\": \"520170763_1783177200000_343892948\",\n    \"title\": \"Climbing Wall\",\n    \"startTime\": \"2026-07-04T11:00:00.000\",\n    \"endTime\": \"2026-07-04T13:00:00.000\",\n    \"locationKey\": \"climbing-wall\",\n    \"locationDisplayName\": \"Climbing Wall\",\n    \"track\": null,\n    \"presenter\": null,\n    \"details\": \"The day never begins until you cling precariously to a cliff face. This activity should be considered a metaphor.\",\n    \"attributes\": [],\n    \"subSchedule\": []\n  },\n  {\n    \"id\": \"794613506_1783177200000_526582537\",\n    \"title\": \"Build Your Own Bloody Mary\",\n    \"startTime\": \"2026-07-04T11:00:00.000\",\n    \"endTime\": \"2026-07-04T12:00:00.000\",\n    \"locationKey\": \"mayfield\",\n    \"locationDisplayName\": \"Lower Mayfield\",\n    \"track\": null,\n    \"presenter\": null,\n    \"details\": \"All the spices and fixin's you could ask for! Come make your own Bloody Mary with or without advice from your host Casey.\",\n    \"attributes\": [\n      \"21+\"\n    ],\n    \"subSchedule\": []\n  },\n  {\n    \"id\": \"1044718038_1783180800000_859746281\",\n    \"title\": \"Ho-Ho-Hoax! (Holiday Movie Film or Fiction)\",\n    \"startTime\": \"2026-07-04T12:00:00.000\",\n    \"endTime\": \"2026-07-04T13:00:00.000\",\n    \"locationKey\": \"theater\",\n    \"locationDisplayName\": \"Theater\",\n    \"track\": null,\n    \"presenter\": null,\n    \"details\": null,\n    \"attributes\": [],\n    \"subSchedule\": []\n  },\n  {\n    \"id\": \"799226954_1783180800000_343892948\",\n    \"title\": \"Archery\",\n    \"startTime\": \"2026-07-04T12:00:00.000\",\n    \"endTime\": \"2026-07-04T15:00:00.000\",\n    \"locationKey\": \"archery\",\n    \"locationDisplayName\": \"Archery Field\",\n    \"track\": null,\n    \"presenter\": null,\n    \"details\": \"Whether you imagine yourself as Robin Hood or Hawkeye, you owe yourself a chance to see how you stack up!\",\n    \"attributes\": [],\n    \"subSchedule\": []\n  },\n  {\n    \"id\": \"86924605_1783180800000_882378525\",\n    \"title\": \"Fantasy Map Making Workshop\",\n    \"startTime\": \"2026-07-04T12:00:00.000\",\n    \"endTime\": \"2026-07-04T13:00:00.000\",\n    \"locationKey\": \"cafeteria\",\n    \"locationDisplayName\": \"Lodge\",\n    \"track\": null,\n    \"presenter\": null,\n    \"details\": \"Create your own magical map using stamps, specialty papers, inks, textures, and mixed-media tools. Participants will design fantasy lands filled with winding rivers, hidden forests, mountain kingdoms, mysterious ruins, and secret paths. Perfect for storytellers, artists, D&D players, and anyone who wants to build a world on paper, no cartography experience required.\",\n    \"attributes\": [],\n    \"subSchedule\": []\n  },\n  {\n    \"id\": \"983470058_1783180800000_343892948\",\n    \"title\": \"Boat On!\",\n    \"startTime\": \"2026-07-04T12:00:00.000\",\n    \"endTime\": \"2026-07-04T14:00:00.000\",\n    \"locationKey\": \"dock-canoes\",\n    \"locationDisplayName\": \"Dock & Canoes\",\n    \"track\": null,\n    \"presenter\": null,\n    \"details\": \"Take a leisurely trip afloat on Lay Lake. Pick from Canoes, Kayaks and Paddleboards! Canoeing sessions are limited to 30 people.\",\n    \"attributes\": [],\n    \"subSchedule\": []\n  },\n  {\n    \"id\": \"290937776_1783184400000_433551012\",\n    \"title\": \"Minecraft Build Competition\",\n    \"startTime\": \"2026-07-04T13:00:00.000\",\n    \"endTime\": \"2026-07-04T15:00:00.000\",\n    \"locationKey\": \"gaming\",\n    \"locationDisplayName\": \"Video Gaming\",\n    \"track\": null,\n    \"presenter\": null,\n    \"details\": null,\n    \"attributes\": [],\n    \"subSchedule\": []\n  },\n  {\n    \"id\": \"51772571_1783184400000_526582537\",\n    \"title\": \"White Elephant Cocktail\",\n    \"startTime\": \"2026-07-04T13:00:00.000\",\n    \"endTime\": \"2026-07-04T14:00:00.000\",\n    \"locationKey\": \"mayfield\",\n    \"locationDisplayName\": \"Lower Mayfield\",\n    \"track\": null,\n    \"presenter\": null,\n    \"details\": \"Join your host Jared for White Elephant or Dirty Santa (depending on who you ask). Come choose a cocktail card, but be careful, you might not get to keep it for long! He will jam out the cocktails as they are picked. No gifts please, just bring yourself!\",\n    \"attributes\": [\n      \"21+\"\n    ],\n    \"subSchedule\": []\n  },\n  {\n    \"id\": \"560444744_1783184400000_982518793\",\n    \"title\": \"Magic The Gathering : Secrets of Strixhaven\",\n    \"startTime\": \"2026-07-04T13:00:00.000\",\n    \"endTime\": \"2026-07-04T16:00:00.000\",\n    \"locationKey\": \"gaming\",\n    \"locationDisplayName\": \"Gaming\",\n    \"track\": null,\n    \"presenter\": null,\n    \"details\": null,\n    \"attributes\": [],\n    \"subSchedule\": []\n  },\n  {\n    \"id\": \"77999203_1783184400000_882378525\",\n    \"title\": \"Pictures with Santa!\",\n    \"startTime\": \"2026-07-04T13:00:00.000\",\n    \"endTime\": \"2026-07-04T15:00:00.000\",\n    \"locationKey\": \"cafeteria\",\n    \"locationDisplayName\": \"Lodge\",\n    \"track\": null,\n    \"presenter\": null,\n    \"details\": \"It's an Olan Mills Miracle!\\n\\n\\\"The line in this mall isn't TOO long. Maybe this year he won't smell quite as bad as last year's Santa. Wait, that's him? Isn't he a little… I dunno… skinny to be Santa? That pillow isn't doing him justice. Maybe this picture will be good for the holiday card we're sending out. Did you make sure all the kids knew how to ask for their present? Wait, who's THAT?!?!\\\"\\n\\nWes and Dan invite you to come get Polaroid pictures with Santa in the Lodge!\",\n    \"attributes\": [],\n    \"subSchedule\": [\n      {\n        \"label\": \"1\",\n        \"time\": \"2026-07-04T14:30:00.000\"\n      }\n    ]\n  },\n  {\n    \"id\": \"974002021_1783184400000_859746281\",\n    \"title\": \"Craft and Chill\",\n    \"startTime\": \"2026-07-04T13:00:00.000\",\n    \"endTime\": \"2026-07-04T14:00:00.000\",\n    \"locationKey\": \"theater\",\n    \"locationDisplayName\": \"Theater\",\n    \"track\": null,\n    \"presenter\": null,\n    \"details\": null,\n    \"attributes\": [\n      \"SF\"\n    ],\n    \"subSchedule\": []\n  },\n  {\n    \"id\": \"905360375_1783188000000_590535442\",\n    \"title\": \"Poolside Karaoke\",\n    \"startTime\": \"2026-07-04T14:00:00.000\",\n    \"endTime\": \"2026-07-04T16:00:00.000\",\n    \"locationKey\": \"pool\",\n    \"locationDisplayName\": \"Pool\",\n    \"track\": null,\n    \"presenter\": null,\n    \"details\": \"Croon poolside for some afternoon delight… full karaoke goodness. Sing loud, sing proud, and make everyone at the 4-H know you're there!\",\n    \"attributes\": [],\n    \"subSchedule\": []\n  },\n  {\n    \"id\": \"980827325_1783188000000_859746281\",\n    \"title\": \"Ummm... Actually!\",\n    \"startTime\": \"2026-07-04T14:00:00.000\",\n    \"endTime\": \"2026-07-04T15:00:00.000\",\n    \"locationKey\": \"theater\",\n    \"locationDisplayName\": \"Theater\",\n    \"track\": null,\n    \"presenter\": null,\n    \"details\": null,\n    \"attributes\": [],\n    \"subSchedule\": []\n  },\n  {\n    \"id\": \"149324008_1783191600000_982518793\",\n    \"title\": \"My First Carcassonne Learn and Play (Treehouse)\",\n    \"startTime\": \"2026-07-04T15:00:00.000\",\n    \"endTime\": \"2026-07-04T16:00:00.000\",\n    \"locationKey\": \"gaming\",\n    \"locationDisplayName\": \"Gaming\",\n    \"track\": null,\n    \"presenter\": null,\n    \"details\": null,\n    \"attributes\": [],\n    \"subSchedule\": []\n  },\n  {\n    \"id\": \"698806821_1783191600000_526582537\",\n    \"title\": \"Open Cantina\",\n    \"startTime\": \"2026-07-04T15:00:00.000\",\n    \"endTime\": \"2026-07-04T19:00:00.000\",\n    \"locationKey\": \"mayfield\",\n    \"locationDisplayName\": \"Lower Mayfield\",\n    \"track\": null,\n    \"presenter\": null,\n    \"details\": \"Come chill out in Lower Mayfield with us! We'll be serving and have the area open for people to relax. There maybe classes going on as well.\",\n    \"attributes\": [\n      \"18+\"\n    ],\n    \"subSchedule\": []\n  },\n  {\n    \"id\": \"89440516_1783191600000_343892948\",\n    \"title\": \"Color Wars ALL AGES!\",\n    \"startTime\": \"2026-07-04T15:00:00.000\",\n    \"endTime\": \"2026-07-04T17:00:00.000\",\n    \"locationKey\": \"picnic-tables\",\n    \"locationDisplayName\": \"Canopy\",\n    \"track\": null,\n    \"presenter\": null,\n    \"details\": null,\n    \"attributes\": [],\n    \"subSchedule\": []\n  },\n  {\n    \"id\": \"230689971_1783195200000_982518793\",\n    \"title\": \"Castle Combo\",\n    \"startTime\": \"2026-07-04T16:00:00.000\",\n    \"endTime\": \"2026-07-04T18:00:00.000\",\n    \"locationKey\": \"gaming\",\n    \"locationDisplayName\": \"Gaming\",\n    \"track\": null,\n    \"presenter\": null,\n    \"details\": null,\n    \"attributes\": [],\n    \"subSchedule\": [\n      {\n        \"label\": \"Learn to Play\",\n        \"time\": \"2026-07-04T16:00:00.000\"\n      },\n      {\n        \"label\": \"Tournament\",\n        \"time\": \"2026-07-04T16:30:00.000\"\n      }\n    ]\n  },\n  {\n    \"id\": \"344193094_1783198800000_433551012\",\n    \"title\": \"Super Smash Brothers Ultimate Doubles\",\n    \"startTime\": \"2026-07-04T17:00:00.000\",\n    \"endTime\": \"2026-07-04T20:00:00.000\",\n    \"locationKey\": \"gaming\",\n    \"locationDisplayName\": \"Video Gaming\",\n    \"track\": null,\n    \"presenter\": null,\n    \"details\": null,\n    \"attributes\": [],\n    \"subSchedule\": []\n  },\n  {\n    \"id\": \"774559720_1783198800000_343892948\",\n    \"title\": \"Beer Croquet (Field)\",\n    \"startTime\": \"2026-07-04T17:00:00.000\",\n    \"endTime\": \"2026-07-04T19:00:00.000\",\n    \"locationKey\": null,\n    \"locationDisplayName\": \"Outdoors\",\n    \"track\": null,\n    \"presenter\": null,\n    \"details\": \"Join The Reverend for a round of BYOB croquet! One hand MUST be distracted with a beverage to play. Seersucker suits are appropriate. 21+ Only!\",\n    \"attributes\": [\n      \"21+\"\n    ],\n    \"subSchedule\": []\n  },\n  {\n    \"id\": \"862887527_1783198800000_526582537\",\n    \"title\": \"Tis the Season to Make Punch!\",\n    \"startTime\": \"2026-07-04T17:00:00.000\",\n    \"endTime\": \"2026-07-04T17:30:00.000\",\n    \"locationKey\": \"mayfield\",\n    \"locationDisplayName\": \"Lower Mayfield\",\n    \"track\": null,\n    \"presenter\": null,\n    \"details\": \"Nothing says holiday gathering quite like a punch bowl. Join Lisa for a spirited tour through punch's 400-year history, from East India Company sailors to George Washington's Christmas bowl to your next holiday party. Learn the legendary five-element formula, explore many classics, and walk away with recipes that will make you the most dangerous host of the season.\",\n    \"attributes\": [\n      \"21+\"\n    ],\n    \"subSchedule\": []\n  },\n  {\n    \"id\": \"99447580_1783198800000_882378525\",\n    \"title\": \"Dinner Theater - Holiday Trivia\",\n    \"startTime\": \"2026-07-04T17:00:00.000\",\n    \"endTime\": \"2026-07-04T18:00:00.000\",\n    \"locationKey\": \"cafeteria\",\n    \"locationDisplayName\": \"Lodge\",\n    \"track\": null,\n    \"presenter\": null,\n    \"details\": \"Are you the kind of person who loves Flag Day? Tell your friends about Festivus? Just really good at random knowledge? Come play pub style trivia with a festive flair! Teams will compete in two rounds of ten questions each with more excitement than Christmas morning!\",\n    \"attributes\": [],\n    \"subSchedule\": []\n  },\n  {\n    \"id\": \"509500074_1783200600000_526582537\",\n    \"title\": \"Adult Karaoke\",\n    \"startTime\": \"2026-07-04T17:30:00.000\",\n    \"endTime\": \"2026-07-04T19:00:00.000\",\n    \"locationKey\": \"mayfield\",\n    \"locationDisplayName\": \"Lower Mayfield\",\n    \"track\": null,\n    \"presenter\": null,\n    \"details\": null,\n    \"attributes\": [\n      \"18+\"\n    ],\n    \"subSchedule\": []\n  },\n  {\n    \"id\": \"328537058_1783202400000_982518793\",\n    \"title\": \"Carnival Of Doom TTRPG\",\n    \"startTime\": \"2026-07-04T18:00:00.000\",\n    \"endTime\": \"2026-07-04T21:00:00.000\",\n    \"locationKey\": \"gaming\",\n    \"locationDisplayName\": \"Gaming\",\n    \"track\": null,\n    \"presenter\": null,\n    \"details\": \"Carnival of Doom Come have a fun day at the carnival and play some games and win some prizes you may or may not know you want or need, they are to die for! We promise you'll have a killer good time! The best part is you never have to leave (even if you want to)! Ages 12+.\",\n    \"attributes\": [\n      \"PG13\"\n    ],\n    \"subSchedule\": []\n  },\n  {\n    \"id\": \"184572897_1783206000000_859746281\",\n    \"title\": \"Costume Contest & Presidential Elections\",\n    \"startTime\": \"2026-07-04T19:00:00.000\",\n    \"endTime\": \"2026-07-04T20:00:00.000\",\n    \"locationKey\": \"theater\",\n    \"locationDisplayName\": \"Theater\",\n    \"track\": null,\n    \"presenter\": null,\n    \"details\": null,\n    \"attributes\": [],\n    \"subSchedule\": []\n  },\n  {\n    \"id\": \"145693448_1783209600000_526582537\",\n    \"title\": \"Cantina Counter Service\",\n    \"startTime\": \"2026-07-04T20:00:00.000\",\n    \"endTime\": \"2026-07-05T02:00:00.000\",\n    \"locationKey\": \"mayfield\",\n    \"locationDisplayName\": \"Lower Mayfield\",\n    \"track\": null,\n    \"presenter\": null,\n    \"details\": \"We'll be serving so you can have some refreshments while enjoying the other events!\",\n    \"attributes\": [\n      \"21+\"\n    ],\n    \"subSchedule\": []\n  },\n  {\n    \"id\": \"738519796_1783209600000_343892948\",\n    \"title\": \"8:30 PM POC: Holiday Variety Show ALL AGES!!\",\n    \"startTime\": \"2026-07-04T20:00:00.000\",\n    \"endTime\": \"2026-07-04T22:00:00.000\",\n    \"locationKey\": \"picnic-tables\",\n    \"locationDisplayName\": \"Canopy\",\n    \"track\": null,\n    \"presenter\": null,\n    \"details\": null,\n    \"attributes\": [],\n    \"subSchedule\": []\n  },\n  {\n    \"id\": \"412176512_1783213200000_859746281\",\n    \"title\": \"Apprentice Movie Night (8:30 PM - 12 AM)\",\n    \"startTime\": \"2026-07-04T21:00:00.000\",\n    \"endTime\": \"2026-07-05T00:00:00.000\",\n    \"locationKey\": \"theater\",\n    \"locationDisplayName\": \"Theater\",\n    \"track\": null,\n    \"presenter\": null,\n    \"details\": \"A line-up of family-friendly movies for our Apprentices to enjoy!\",\n    \"attributes\": [\n      \"AT\"\n    ],\n    \"subSchedule\": []\n  },\n  {\n    \"id\": \"832899095_1783213200000_982518793\",\n    \"title\": \"Goblin Quest TTRPG\",\n    \"startTime\": \"2026-07-04T21:00:00.000\",\n    \"endTime\": \"2026-07-05T00:00:00.000\",\n    \"locationKey\": \"gaming\",\n    \"locationDisplayName\": \"Gaming\",\n    \"track\": null,\n    \"presenter\": null,\n    \"details\": \"Goblin Quest is a tabletop roleplaying game about slapstick violence, fatal ineptitude, and the greatest adventure of your life. Play five goblins each (in sequence, not parallel) and watch them meet hilarious ends while failing to achieve the most basic tasks. Will they survive the dangerous world of the Great Battle Camp and avoid the attentions of brutal orcs, murderous bugbears, mean-spirited hobgoblins and scary wizards? Probably not. But you'll have fun finding out! Ages 12+.\",\n    \"attributes\": [\n      \"PG13\"\n    ],\n    \"subSchedule\": []\n  },\n  {\n    \"id\": \"341352671_1783216800000_343892948\",\n    \"title\": \"Presidential Election Results\",\n    \"startTime\": \"2026-07-04T22:00:00.000\",\n    \"endTime\": \"2026-07-04T23:00:00.000\",\n    \"locationKey\": \"picnic-tables\",\n    \"locationDisplayName\": \"Canopy\",\n    \"track\": null,\n    \"presenter\": null,\n    \"details\": null,\n    \"attributes\": [],\n    \"subSchedule\": []\n  },\n  {\n    \"id\": \"421309781_1783216800000_433551012\",\n    \"title\": \"Free Play / Johann Sebastian Joust\",\n    \"startTime\": \"2026-07-04T22:00:00.000\",\n    \"endTime\": \"2026-07-05T01:00:00.000\",\n    \"locationKey\": \"gaming\",\n    \"locationDisplayName\": \"Video Gaming\",\n    \"track\": null,\n    \"presenter\": null,\n    \"details\": null,\n    \"attributes\": [],\n    \"subSchedule\": []\n  },\n  {\n    \"id\": \"611559714_1783216800000_526582537\",\n    \"title\": \"Party (Lower Alfa Dorm)\",\n    \"startTime\": \"2026-07-04T22:00:00.000\",\n    \"endTime\": \"2026-07-05T00:00:00.000\",\n    \"locationKey\": \"mayfield\",\n    \"locationDisplayName\": \"Lower Mayfield\",\n    \"track\": null,\n    \"presenter\": null,\n    \"details\": null,\n    \"attributes\": [\n      \"18+\"\n    ],\n    \"subSchedule\": []\n  },\n  {\n    \"id\": \"49575508_1783218600000_343892948\",\n    \"title\": \"Iron Bartender\",\n    \"startTime\": \"2026-07-04T22:30:00.000\",\n    \"endTime\": \"2026-07-05T00:30:00.000\",\n    \"locationKey\": \"picnic-tables\",\n    \"locationDisplayName\": \"Canopy\",\n    \"track\": null,\n    \"presenter\": null,\n    \"details\": \"Superior Mixmasters battle neophyte challengers in number one challenge to the death! Judges demand drinks with secret ingredient, and bartenders do as they are told. Watch as Cocktail Stadium becomes mighty arena of conflict!\",\n    \"attributes\": [\n      \"18+\"\n    ],\n    \"subSchedule\": []\n  },\n  {\n    \"id\": \"980804450_1783220400000_982518793\",\n    \"title\": \"Blood on the Clocktower\",\n    \"startTime\": \"2026-07-04T23:00:00.000\",\n    \"endTime\": \"2026-07-05T01:00:00.000\",\n    \"locationKey\": \"gaming\",\n    \"locationDisplayName\": \"Gaming\",\n    \"track\": null,\n    \"presenter\": null,\n    \"details\": \"A scream echoes through the sleepy town of Ravenswood Bluff. The townsfolk rush to investigate and find the beloved local storyteller has been murdered, their body hanging limp from the clocktower. As blood drips onto the cobblestones below, a realization slowly dawns… a demon has been unleashed, killing by night and taking on human form by day. Can good find the demon in time? Or will evil overrun this once peaceful town?\\n\\nBlood on the Clocktower is a game of murder and mystery, lies and logic, deduction and deception for five-to-twenty courageous players and one devious storyteller.\\n\\nA social game played in person, seated in a circle, each player receives either a 'good' or 'evil' token with their unique character on it. Good players share information to solve the mystery whilst evil players lie about who they are and what they know. The good team wins if they can piece together their knowledge, trust each other, and execute the demon. The evil team wins if the demon can sow distrust, evade detection, and wipe out the village.\",\n    \"attributes\": [],\n    \"subSchedule\": []\n  },\n  {\n    \"id\": \"530947669_1783224000000_590535442\",\n    \"title\": \"Adult Swim\",\n    \"startTime\": \"2026-07-05T00:00:00.000\",\n    \"endTime\": \"2026-07-05T02:00:00.000\",\n    \"locationKey\": \"pool\",\n    \"locationDisplayName\": \"Pool\",\n    \"track\": null,\n    \"presenter\": null,\n    \"details\": null,\n    \"attributes\": [\n      \"21+\"\n    ],\n    \"subSchedule\": []\n  },\n  {\n    \"id\": \"662146075_1783224000000_526582537\",\n    \"title\": \"After Dark Party (Lower Alfa Dorm)\",\n    \"startTime\": \"2026-07-05T00:00:00.000\",\n    \"endTime\": \"2026-07-05T02:00:00.000\",\n    \"locationKey\": \"mayfield\",\n    \"locationDisplayName\": \"Lower Mayfield\",\n    \"track\": null,\n    \"presenter\": null,\n    \"details\": null,\n    \"attributes\": [\n      \"21+\"\n    ],\n    \"subSchedule\": []\n  },\n  {\n    \"id\": \"388856022_1783260000000_526582537\",\n    \"title\": \"Coffee Service\",\n    \"startTime\": \"2026-07-05T10:00:00.000\",\n    \"endTime\": \"2026-07-05T11:00:00.000\",\n    \"locationKey\": \"mayfield\",\n    \"locationDisplayName\": \"Lower Mayfield\",\n    \"track\": null,\n    \"presenter\": null,\n    \"details\": \"Your morning pick-me-up. Coffee with a variety of creamer and sweetener options will be available. A keurig is available if you'd like to bring your own special pods. 21+ may come inside Mayfield if you'd like some additions to your coffee.\",\n    \"attributes\": [\n      \"SF\"\n    ],\n    \"subSchedule\": []\n  },\n  {\n    \"id\": \"642922614_1783263600000_882378525\",\n    \"title\": \"Con in Review\",\n    \"startTime\": \"2026-07-05T11:00:00.000\",\n    \"endTime\": \"2026-07-05T12:00:00.000\",\n    \"locationKey\": \"cafeteria\",\n    \"locationDisplayName\": \"Lodge\",\n    \"track\": null,\n    \"presenter\": null,\n    \"details\": \"We consider this convention to be a community event. Your input is not only desired but needed if we are to make POC into the best convention it can be. Please join us as we discuss Play On Con 2026 and plan for POC 20 in 2027.\",\n    \"attributes\": [],\n    \"subSchedule\": []\n  }\n]\n";
const _captureScenarioJson = "{\n  \"now\": \"2026-07-02T15:45:00\",\n  \"saved_titles\": [\n    \"Make a Holiday Card\",\n    \"Nidhogg Tournament\",\n    \"How To: Tie-Dye\",\n    \"Easter Egg Hunt\"\n  ],\n  \"detail_title\": \"Make a Holiday Card\"\n}\n";
const _captureConfigJson = "{\n  \"POC_EVENT_THURSDAY\": \"2026-07-02\",\n  \"POC_SCHEDULE_VIEW_URL\": \"https://docs.google.com/spreadsheets/d/1uMrBl9oFz9CWTfJX5eET-3bguERKpZ4IahPbFdpFqT0/edit?usp=sharing\",\n  \"POC_DISCORD_INVITE_URL\": \"https://discord.gg/4GQgGnXN5\",\n  \"POC_PROGRAM_URL\": \"https://drive.google.com/file/d/1sx46MEfKEBswAv_wDgk3Ly1c6PX-ECIB/view?usp=sharing\"\n}\n";
// END FROZEN CAPTURE DATA
