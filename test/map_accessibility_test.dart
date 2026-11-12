import 'dart:async';
import 'dart:ui' show Tristate;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:playoncon/app_navigation.dart';
import 'package:playoncon/features/map/venue_map_page.dart';
import 'package:playoncon/models/cart_position.dart';
import 'package:playoncon/models/event.dart';
import 'package:playoncon/models/venue_location.dart';
import 'package:playoncon/services/app_clock.dart';
import 'package:playoncon/services/calibration_store.dart';
import 'package:playoncon/services/cart_positions_repository.dart';
import 'package:playoncon/services/last_tab_store.dart';
import 'package:playoncon/services/location_service.dart';
import 'package:playoncon/services/schedule_repository.dart';
import 'package:playoncon/theme/poc_theme.dart';

const _geolocationChannel = MethodChannel('flutter.baseflow.com/geolocator');

class _EmptyCalibrationStore extends CalibrationStore {
  @override
  Future<List<CalibrationPoint>> load() async => [];
}

final _places = [
  VenueLocation(
    key: 'theater',
    displayName: 'Theater',
    rect: const NormalizedRect(x: 0.38, y: 0.33, w: 0.04, h: 0.04),
  ),
  VenueLocation(
    key: 'cottages',
    displayName: 'Cottages and Accessible Lodging',
    rect: const NormalizedRect(x: 0.5, y: 0.84, w: 0.04, h: 0.04),
  ),
];

final _position = Position(
  latitude: 33.16739,
  longitude: -86.49395,
  timestamp: DateTime(2026, 7, 4),
  accuracy: 5,
  altitude: 0,
  altitudeAccuracy: 0,
  heading: 0,
  headingAccuracy: 0,
  speed: 0,
  speedAccuracy: 0,
);

CartPosition _cart(String name) => CartPosition(
  cartId: name,
  displayName: name,
  driverName: 'Morgan',
  lat: _position.latitude,
  lng: _position.longitude,
  updatedAt: DateTime(2026, 7, 4),
);

class _FixedSchedule extends ScheduleRepository {
  _FixedSchedule(super.ref, List<Event> events) {
    state = ScheduleState(events: events);
  }

  @override
  Future<void> bootstrap() async {}
}

Future<void> _openMap(
  WidgetTester tester, {
  List<Event>? events,
  DateTime Function()? clock,
  double textScale = 1,
  bool locationGranted = false,
  int selectedTab = mapTabIndex,
  Stream<Map<String, CartPosition>>? carts,
  Stream<Position>? positions,
  VoidCallback? onPositionSubscribed,
}) async {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(_geolocationChannel, (call) async {
        if (call.method == 'checkPermission') {
          return locationGranted ? 2 : 0;
        }
        throw PlatformException(code: 'Unexpected method ${call.method}');
      });
  addTearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_geolocationChannel, null);
  });
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        venueLocationsProvider.overrideWith((_) async => _places),
        mapDebugToolsProvider.overrideWithValue(false),
        calibrationStoreProvider.overrideWithValue(_EmptyCalibrationStore()),
        if (events == null)
          scheduleRepositoryProvider.overrideWith(ScheduleRepository.new)
        else
          scheduleRepositoryProvider.overrideWith(
            (ref) => _FixedSchedule(ref, events),
          ),
        if (clock != null) appClockProvider.overrideWithValue(clock),
        // The map only streams GPS while its tab is selected.
        selectedTabProvider.overrideWith((_) => LastTabStore(selectedTab)),
        cartPositionsProvider.overrideWith(
          (_) => carts ?? Stream.value(const {}),
        ),
        currentPositionProvider.overrideWith((_) {
          onPositionSubscribed?.call();
          return positions ?? Stream.value(_position);
        }),
      ],
      child: MaterialApp(
        theme: PocTheme.light(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            textScaler: TextScaler.linear(textScale),
            disableAnimations: true,
          ),
          child: child!,
        ),
        home: const VenueMapPage(),
      ),
    ),
  );
  for (
    var i = 0;
    i < 30 && find.byType(InteractiveViewer).evaluate().isEmpty;
    i++
  ) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump();
  }
  await tester.pumpAndSettle();
  expect(find.byType(InteractiveViewer), findsOneWidget);
}

void main() {
  testWidgets(
    'Places reaches every venue at 200% text and returns to details',
    (tester) async {
      final semantics = tester.ensureSemantics();
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(320, 640);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await _openMap(tester, textScale: 2);
      expect(find.byTooltip('Places').hitTestable(), findsOneWidget);
      expect(tester.getSemantics(find.byTooltip('Places')).tooltip, 'Places');
      await tester.tap(find.byTooltip('Places'));
      await tester.pumpAndSettle();
      final cottages = find.byKey(const ValueKey('place-cottages'));
      await tester.scrollUntilVisible(cottages, 160);
      await tester.pumpAndSettle();
      expect(find.text(_places.last.displayName), findsOneWidget);
      expect(
        find.textContaining(
          'Lodging cabins. Approximate position: lower center',
        ),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      await tester.tap(cottages);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('venue-info-cottages')), findsOneWidget);
      expect(
        tester
            .getSemantics(find.byKey(const ValueKey('venue-pin-cottages')))
            .flagsCollection
            .isSelected,
        Tristate.isTrue,
      );
      expect(tester.takeException(), isNull);
      semantics.dispose();
    },
  );

  testWidgets('venue pin has keyboard focus and Enter opens its details', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    await _openMap(tester);
    for (final (tooltip, icon) in [
      ('Places', Icons.list_alt),
      ('Overview', Icons.zoom_out_map),
      ('Show my location', Icons.location_searching),
    ]) {
      final control = find.byTooltip(tooltip);
      final glyph = find.descendant(of: control, matching: find.byIcon(icon));
      Focus.of(tester.element(glyph)).requestFocus();
      await tester.pumpAndSettle();
      final flags = tester
          .getSemantics(
            tooltip == 'Places' ? control : find.bySemanticsLabel(tooltip),
          )
          .flagsCollection;
      expect(flags.isEnabled, Tristate.isTrue, reason: tooltip);
      expect(flags.isFocused, Tristate.isTrue, reason: tooltip);
      expect(flags.isButton, isTrue, reason: tooltip);
      if (tooltip != 'Places') {
        expect(find.bySemanticsLabel(tooltip), findsOneWidget);
      }
    }
    final pin = find.byKey(const ValueKey('venue-pin-theater'));
    final glyph = find.descendant(
      of: pin,
      matching: find.byIcon(Icons.theater_comedy),
    );
    final focus = Focus.of(tester.element(glyph));
    focus.requestFocus();
    await tester.pumpAndSettle();
    expect(focus.hasFocus, isTrue);
    final flags = tester.getSemantics(pin).flagsCollection;
    expect(flags.isEnabled, Tristate.isTrue);
    expect(flags.isFocused, Tristate.isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('venue-info-theater')), findsOneWidget);
    expect(tester.takeException(), isNull);
    semantics.dispose();
  });

  testWidgets(
    'location and live carts have approximate landmark descriptions',
    (tester) async {
      final semantics = tester.ensureSemantics();
      final carts = StreamController<Map<String, CartPosition>>();
      addTearDown(carts.close);
      await _openMap(tester, locationGranted: true, carts: carts.stream);
      carts.add({'blue': _cart('Blue Cart')});
      await tester.pumpAndSettle();
      expect(
        find.bySemanticsLabel(
          RegExp('Your location.*Nearest mapped place: Theater'),
        ),
        findsOneWidget,
      );
      expect(
        find.bySemanticsLabel(
          RegExp('Blue Cart.*Morgan.*Nearest mapped place: Theater'),
        ),
        findsOneWidget,
      );
      await tester.tap(find.byTooltip('Places'));
      await tester.pumpAndSettle();
      expect(find.text('Blue Cart'), findsOneWidget);
      expect(find.textContaining('Driver: Morgan.'), findsOneWidget);
      expect(
        find.textContaining('Nearest mapped place: Theater'),
        findsNWidgets(2),
      );
      carts.add({'green': _cart('Green Cart')});
      await tester.pumpAndSettle();
      expect(find.text('Blue Cart'), findsNothing);
      expect(find.text('Green Cart'), findsOneWidget);
      expect(tester.takeException(), isNull);
      semantics.dispose();
    },
  );

  testWidgets('Places keeps location opt-in', (tester) async {
    var subscriptions = 0;
    await _openMap(tester, onPositionSubscribed: () => subscriptions++);
    await tester.tap(find.byTooltip('Places'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Location is off.'), findsOneWidget);
    expect(subscriptions, 0);
  });

  testWidgets('an open venue sheet follows the session clock', (
    tester,
  ) async {
    Event session(String title, int hour) => Event(
      id: title,
      title: title,
      startTime: DateTime(2026, 7, 3, hour),
      endTime: DateTime(2026, 7, 3, hour + 1),
      locationKey: 'theater',
      locationDisplayName: 'Theater',
    );
    var now = DateTime(2026, 7, 3, 19, 58);
    await _openMap(
      tester,
      events: [session('Werewolf', 19), session('Karaoke', 20)],
      clock: () => now,
    );
    await tester.tap(find.byKey(const ValueKey('venue-pin-theater')));
    await tester.pumpAndSettle();
    expect(find.text('Now: Werewolf'), findsOneWidget);

    now = DateTime(2026, 7, 3, 20, 0, 30);
    await tester.pump(const Duration(minutes: 1));
    expect(find.text('Now: Werewolf'), findsNothing);
    expect(find.text('Now: Karaoke'), findsOneWidget);
  });

  testWidgets('locate says it is searching before the first GPS fix', (
    tester,
  ) async {
    final positions = StreamController<Position>();
    addTearDown(positions.close);
    await _openMap(tester, locationGranted: true, positions: positions.stream);
    await tester.tap(find.byTooltip('Center on my location'));
    await tester.pump();
    expect(find.text('Finding your location\u2026'), findsOneWidget);
  });

  testWidgets('GPS only streams while the Map tab is selected', (tester) async {
    // Every tab stays mounted, so the map must not hold the position stream
    // open behind the Schedule and Info tabs.
    var subscriptions = 0;
    await _openMap(
      tester,
      locationGranted: true,
      selectedTab: 0,
      onPositionSubscribed: () => subscriptions++,
    );
    expect(subscriptions, 0);

    final container = ProviderScope.containerOf(
      tester.element(find.byType(VenueMapPage)),
    );
    container.read(selectedTabProvider.notifier).state = mapTabIndex;
    await tester.pumpAndSettle();
    expect(subscriptions, 1);
  });
}
