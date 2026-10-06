// Render the production Android interface with frozen, offline fixture data.
// Run scripts/capture-store-assets.sh for the fixed public Info-page config.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:playoncon/app.dart';
import 'package:playoncon/app_navigation.dart';
import 'package:playoncon/config/app_config.dart';
import 'package:playoncon/features/map/venue_map_page.dart';
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
import 'package:playoncon/services/saved_events_store.dart';
import 'package:playoncon/services/schedule_repository.dart';
import 'package:playoncon/theme/poc_theme.dart';
import 'package:timezone/data/latest.dart' as tz_data;
import 'package:timezone/timezone.dart' as tz;

class _CaptureRepository extends ScheduleRepository {
  _CaptureRepository(super.ref, List<Event> events) {
    state = ScheduleState(
      events: events,
      lastSyncAt: tz.TZDateTime(
        tz.getLocation('America/Chicago'),
        2026,
        7,
        2,
        15,
      ),
    );
  }

  @override
  Future<void> bootstrap() async {}
  @override
  Future<void> refresh() async {}
}

class _CaptureSaves extends SavedEventsStore {
  _CaptureSaves(List<Event> events, List<String> titles) {
    state = {
      for (final event in events.where((e) => titles.contains(e.title)))
        event.id: const Reminder.minutes(15),
    };
  }
}

class _CaptureTab extends LastTabStore {
  _CaptureTab() : super(0);
  @override
  void set(int index) => state = index;
}

class _EmptyCalibrationStore extends CalibrationStore {
  @override
  Future<List<CalibrationPoint>> load() async => [];
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

// Event data normally represents venue wall-clock time. Give fixture dates
// their explicit venue timezone so a capture also matches on non-US hosts.
Event _fixtureEvent(Map<String, dynamic> json) {
  final event = Event.fromJson(json);
  return Event(
    id: event.id,
    title: event.title,
    startTime: _central(event.startTime),
    endTime: _central(event.endTime),
    locationKey: event.locationKey,
    locationDisplayName: event.locationDisplayName,
    track: event.track,
    presenter: event.presenter,
    details: event.details,
    attributes: event.attributes,
    subSchedule: [
      for (final item in event.subSchedule)
        ScheduleItem(label: item.label, time: _central(item.time)),
    ],
  );
}

Future<void> _loadAndroidFonts() async {
  final configFile = File('.dart_tool/package_config.json');
  final config = jsonDecode(configFile.readAsStringSync()) as Map;
  final package = (config['packages'] as List).cast<Map>().singleWhere(
    (package) => package['name'] == 'flutter',
  );
  final flutter = Directory.fromUri(
    configFile.absolute.uri.resolve(package['rootUri'] as String),
  ).parent.parent;
  final materialFonts = '${flutter.path}/bin/cache/artifacts/material_fonts';
  final roboto = FontLoader('Roboto');
  for (final weight in ['Regular', 'Medium', 'Bold']) {
    final file = File('$materialFonts/Roboto-$weight.ttf');
    if (!file.existsSync()) {
      throw StateError('Roboto missing from the Flutter SDK: ${file.path}');
    }
    roboto.addFont(Future.value(ByteData.sublistView(file.readAsBytesSync())));
  }
  await roboto.load();
  final emojiFile = File(
    Platform.environment['POC_CAPTURE_EMOJI_FONT'] ??
        'tool/fonts/Noto-COLRv1.ttf',
  );
  if (!emojiFile.existsSync()) {
    throw StateError(
      'Android emoji font unavailable. Set POC_CAPTURE_EMOJI_FONT to the '
      'Android Noto COLRv1 emoji font. Refusing to capture missing glyphs.',
    );
  }
  final emoji = FontLoader('Noto Color Emoji')
    ..addFont(Future.value(ByteData.sublistView(emojiFile.readAsBytesSync())));
  await emoji.load();
  final icons = FontLoader('MaterialIcons')
    ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
  await icons.load();
}

ThemeData _androidTheme(Brightness brightness) {
  final theme = brightness == Brightness.light
      ? PocTheme.light()
      : PocTheme.dark();
  return theme.copyWith(
    platform: TargetPlatform.android,
    appBarTheme: theme.appBarTheme.copyWith(
      titleTextStyle: theme.appBarTheme.titleTextStyle?.copyWith(
        fontFamily: 'Roboto',
        fontFamilyFallback: const ['Noto Color Emoji'],
      ),
    ),
    textTheme: theme.textTheme.apply(
      fontFamily: 'Roboto',
      fontFamilyFallback: const ['Noto Color Emoji'],
    ),
    primaryTextTheme: theme.primaryTextTheme.apply(
      fontFamily: 'Roboto',
      fontFamilyFallback: const ['Noto Color Emoji'],
    ),
  );
}

Future<void> _capture(WidgetTester tester, String path) async {
  expect(tester.takeException(), isNull, reason: 'UI error before $path');
  await tester.runAsync(() async {
    final boundary = tester.renderObject<RenderRepaintBoundary>(
      find.byKey(const ValueKey('store-capture')),
    );
    final image = await boundary.toImage(pixelRatio: 3);
    try {
      expect(image.width, 1080);
      expect(image.height, 1920);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      final file = File('design/google-play/$path');
      await file.parent.create(recursive: true);
      // Google Play takes 24-bit RGB PNGs without an alpha channel. Encoding
      // the opaque rendered pixels directly also avoids external image tools.
      await file.writeAsBytes(_rgbPng(image.width, image.height, bytes!));
    } finally {
      image.dispose();
    }
  });
}

Uint8List _rgbPng(int width, int height, ByteData rgba) {
  final output = BytesBuilder()..add([137, 80, 78, 71, 13, 10, 26, 10]);
  void chunk(String type, List<int> data) {
    final payload = [...type.codeUnits, ...data];
    var crc = 0xffffffff;
    for (final byte in payload) {
      crc ^= byte;
      for (var bit = 0; bit < 8; bit++) {
        crc = (crc >> 1) ^ ((crc & 1) == 1 ? 0xedb88320 : 0);
      }
    }
    final length = ByteData(4)..setUint32(0, data.length);
    final checksum = ByteData(4)..setUint32(0, crc ^ 0xffffffff);
    output
      ..add(length.buffer.asUint8List())
      ..add(payload)
      ..add(checksum.buffer.asUint8List());
  }

  final header = ByteData(13)
    ..setUint32(0, width)
    ..setUint32(4, height)
    ..setUint8(8, 8) // Bits per RGB component.
    ..setUint8(9, 2); // PNG truecolor, with no alpha channel.
  chunk('IHDR', header.buffer.asUint8List());
  final scanlines = Uint8List(height * (1 + width * 3));
  var source = 0;
  var target = 0;
  for (var row = 0; row < height; row++) {
    scanlines[target++] = 0; // PNG filter: none.
    for (var col = 0; col < width; col++) {
      for (var component = 0; component < 3; component++) {
        scanlines[target++] = rgba.getUint8(source++);
      }
      if (rgba.getUint8(source++) != 255) {
        throw StateError('Store screenshot has transparent pixels.');
      }
    }
  }
  chunk('IDAT', ZLibEncoder().convert(scanlines));
  chunk('IEND', const []);
  return output.takeBytes();
}

void main() {
  late List<Event> events;
  late List<VenueLocation> locations;
  late Map<String, dynamic> scenario;

  setUpAll(() async {
    final config =
        jsonDecode(
              File('test/fixtures/screenshot-config.json').readAsStringSync(),
            )
            as Map<String, dynamic>;
    final actualConfig = {
      'POC_EVENT_THURSDAY': AppConfig.eventThursday,
      'POC_SCHEDULE_VIEW_URL': AppConfig.scheduleViewUrl,
      'POC_DISCORD_INVITE_URL': AppConfig.discordInviteUrl,
      'POC_PROGRAM_URL': AppConfig.programUrl,
    };
    if (config.entries.any((entry) => actualConfig[entry.key] != entry.value) ||
        AppConfig.hasAppVersion ||
        AppConfig.calibrationEnabled) {
      throw StateError(
        'Store capture requires the frozen public configuration. '
        'Run ./scripts/capture-store-assets.sh from the project root; '
        'do not pass release defines or a build version.',
      );
    }
    tz_data.initializeTimeZones();
    events =
        (jsonDecode(
                  File(
                    'test/fixtures/screenshot-schedule.json',
                  ).readAsStringSync(),
                )
                as List)
            .cast<Map<String, dynamic>>()
            .map(_fixtureEvent)
            .toList();
    scenario =
        jsonDecode(
              File('test/fixtures/screenshot-scenario.json').readAsStringSync(),
            )
            as Map<String, dynamic>;
    locations =
        (jsonDecode(File('assets/data/locations.json').readAsStringSync())
                as List)
            .cast<Map<String, dynamic>>()
            .map(VenueLocation.fromJson)
            .toList();
    await _loadAndroidFonts();
  });

  for (final brightness in [Brightness.light, Brightness.dark]) {
    testWidgets('capture ${brightness.name} Android store screens', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(360, 640);
      tester.view.devicePixelRatio = 1;
      debugDisableShadows = false;
      try {
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        // Native permission and persistence state must never leak into captures.
        final messenger =
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
        const geolocator = MethodChannel('flutter.baseflow.com/geolocator');
        const paths = MethodChannel('plugins.flutter.io/path_provider');
        messenger.setMockMethodCallHandler(geolocator, (call) async => 0);
        messenger.setMockMethodCallHandler(paths, (call) async => null);
        addTearDown(() {
          messenger.setMockMethodCallHandler(geolocator, null);
          messenger.setMockMethodCallHandler(paths, null);
        });
        final savedTitles = (scenario['saved_titles'] as List).cast<String>();
        for (final title in savedTitles) {
          expect(events.any((e) => e.title == title), isTrue, reason: title);
        }
        final clock = _central(DateTime.parse(scenario['now'] as String));
        final prefix = brightness == Brightness.light ? '' : 'dark/';
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              scheduleRepositoryProvider.overrideWith(
                (ref) => _CaptureRepository(ref, events),
              ),
              savedEventsProvider.overrideWith(
                (_) => _CaptureSaves(events, savedTitles),
              ),
              selectedTabProvider.overrideWith((_) => _CaptureTab()),
              appClockProvider.overrideWithValue(() => clock),
              connectivityProvider.overrideWith(
                (_) => Stream.value(const NetworkStatus(true)),
              ),
              venueLocationsProvider.overrideWith((_) async => locations),
              currentPositionProvider.overrideWith((_) => Stream.value(null)),
              cartPositionsProvider.overrideWith(
                (_) => Stream.value(const <String, CartPosition>{}),
              ),
              appleLayoutProvider.overrideWith(
                (_) => Stream.value(const AppleLayout.unavailable()),
              ),
              calibrationStoreProvider.overrideWithValue(
                _EmptyCalibrationStore(),
              ),
              mapDebugToolsProvider.overrideWithValue(false),
            ],
            child: RepaintBoundary(
              key: const ValueKey('store-capture'),
              child: MaterialApp(
                debugShowCheckedModeBanner: false,
                theme: _androidTheme(brightness),
                home: const RootShell(),
              ),
            ),
          ),
        );
        await tester.runAsync(() async {
          final context = tester.element(find.byType(RootShell));
          for (final path in [
            'assets/branding/poc-logo.png',
            'assets/images/venue-map.png',
            'assets/images/venue-map-dark.png',
          ]) {
            await precacheImage(AssetImage(path), context);
          }
        });
        await tester.pumpAndSettle();
        await _capture(tester, '${prefix}01-all-sessions.png');

        await tester.tap(find.widgetWithText(Tab, 'My Schedule'));
        await tester.pumpAndSettle();
        await _capture(tester, '${prefix}02-my-schedule.png');

        final title = scenario['detail_title'] as String;
        await tester.tap(find.text(title).hitTestable());
        await tester.pumpAndSettle();
        await _capture(tester, '${prefix}03-event-detail.png');

        await tester.tap(find.text('Show on map'));
        await tester.pumpAndSettle();
        expect(find.byTooltip('Edit hotspots'), findsNothing);
        expect(find.byTooltip('Calibrate GPS ↔ map'), findsNothing);
        await _capture(tester, '${prefix}04-venue-map.png');

        await tester.tap(find.widgetWithText(NavigationDestination, 'Info'));
        await tester.pumpAndSettle();
        await _capture(tester, '${prefix}05-info.png');
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      } finally {
        // The binding checks painting defaults before package:test teardown.
        debugDisableShadows = true;
      }
    });
  }
}
