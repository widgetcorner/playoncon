import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:playoncon/features/map/venue_map_page.dart';
import 'package:playoncon/models/venue_location.dart';
import 'package:playoncon/services/apple_layout.dart';
import 'package:playoncon/services/calibration_store.dart';
import 'package:playoncon/services/schedule_repository.dart';
import 'package:playoncon/theme/poc_theme.dart';
import 'package:playoncon/widgets/adaptive_navigation.dart';
import 'package:playoncon/widgets/apple_layout_boundary.dart';

class _EmptyCalibrationStore extends CalibrationStore {
  @override
  Future<List<CalibrationPoint>> load() async => [];
}

final _venue = VenueLocation(
  key: 'gaming',
  displayName: 'Main Gaming and Tabletop Adventures',
  rect: const NormalizedRect(x: 0.39, y: 0.39, w: 0.02, h: 0.02),
);

Future<void> _openMap(
  WidgetTester tester, {
  double textScale = 1,
  Widget home = const VenueMapPage(),
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        venueLocationsProvider.overrideWith((ref) async => [_venue]),
        calibrationStoreProvider.overrideWithValue(_EmptyCalibrationStore()),
        scheduleRepositoryProvider.overrideWith(ScheduleRepository.new),
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
        home: home,
      ),
    ),
  );
  // The map asset is decoded asynchronously before the board mounts.
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

TransformationController _controller(WidgetTester tester) => tester
    .widget<InteractiveViewer>(find.byType(InteractiveViewer))
    .transformationController!;

/// Read the actual rendered image rect instead of assuming artwork dimensions.
Offset _mapCenter(WidgetTester tester) {
  final viewerSize = tester.getSize(find.byType(InteractiveViewer));
  final image = find.descendant(
    of: find.byType(InteractiveViewer),
    matching: find.byType(Image),
  );
  final positioned = tester.widget<Positioned>(
    find.ancestor(of: image, matching: find.byType(Positioned)).first,
  );
  final center = _controller(tester).toScene(viewerSize.center(Offset.zero));
  return Offset(
    (center.dx - positioned.left!) / positioned.width!,
    (center.dy - positioned.top!) / positioned.height!,
  );
}

void main() {
  testWidgets(
    'map keeps floating card off crease when the rail changes sides',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(900, 600);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final edge = ValueNotifier(AppleBarEdge.right);
      addTearDown(edge.dispose);
      const fold = Rect.fromLTWH(450, 0, 0, 600);
      const pages = [SizedBox(), VenueMapPage(), SizedBox()];
      await _openMap(
        tester,
        home: ValueListenableBuilder<AppleBarEdge>(
          valueListenable: edge,
          builder: (context, barEdge, child) => AppleLayoutBoundary(
            layout: AppleLayout(
              barEdge: barEdge,
              viewSize: const Size(900, 600),
              divisions: const [fold],
            ),
            child: AdaptiveNavigationScaffold(
              barEdge: barEdge,
              selectedIndex: 1,
              onDestinationSelected: (_) {},
              pages: pages,
            ),
          ),
        ),
      );
      await tester.tap(find.bySemanticsLabel(_venue.displayName));
      await tester.pumpAndSettle();
      final controller = _controller(tester);
      final transform = controller.value.clone();
      final initialBounds = tester.getRect(find.byType(InteractiveViewer));
      final cardFinder = find.byKey(const ValueKey('venue-info-gaming'));
      expect(tester.getRect(cardFinder).overlaps(fold.inflate(0.5)), isFalse);

      edge.value = AppleBarEdge.left;
      await tester.pumpAndSettle();
      final movedBounds = tester.getRect(find.byType(InteractiveViewer));
      expect(movedBounds.size, initialBounds.size);
      expect(movedBounds.left, initialBounds.left + 88);
      expect(_controller(tester), same(controller));
      expect(controller.value, transform);
      expect(tester.getRect(cardFinder).overlaps(fold.inflate(0.5)), isFalse);
      expect(find.byTooltip('Close').hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('folds move floating map controls without shrinking the map', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(900, 600);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final folds = ValueNotifier<List<ui.DisplayFeature>>([]);
    addTearDown(folds.dispose);
    await _openMap(
      tester,
      home: ValueListenableBuilder<List<ui.DisplayFeature>>(
        valueListenable: folds,
        builder: (context, features, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(displayFeatures: features),
          // Exercise scene-to-map coordinates after navigation and safe insets.
          child: const Padding(
            padding: EdgeInsets.fromLTRB(84, 24, 28, 36),
            child: VenueMapPage(),
          ),
        ),
      ),
    );
    await tester.tap(find.bySemanticsLabel(_venue.displayName));
    await tester.pumpAndSettle();
    final initialViewport = tester.getRect(find.byType(InteractiveViewer));
    final controller = _controller(tester);
    await tester.dragFrom(
      initialViewport.topLeft + const Offset(100, 100),
      const Offset(-40, 10),
    );
    await tester.pumpAndSettle();
    final transform = controller.value.clone();
    expect(initialViewport.width, 788);

    for (final fold in [
      const Rect.fromLTWH(450, 0, 0, 600),
      const Rect.fromLTWH(0, 300, 900, 0),
    ]) {
      folds.value = [
        ui.DisplayFeature(
          bounds: fold,
          type: ui.DisplayFeatureType.fold,
          state: ui.DisplayFeatureState.postureHalfOpened,
        ),
      ];
      await tester.pumpAndSettle();
      expect(tester.getRect(find.byType(InteractiveViewer)), initialViewport);
      expect(_controller(tester), same(controller));
      expect(controller.value, transform);
      final card = tester.getRect(
        find.byKey(const ValueKey('venue-info-gaming')),
      );
      expect(card.overlaps(fold.inflate(0.5)), isFalse);
      for (final tooltip in ['Overview', 'Show my location', 'Close']) {
        final control = find.byTooltip(tooltip);
        expect(control.hitTestable(), findsOneWidget);
        expect(tester.getRect(control).overlaps(fold.inflate(0.5)), isFalse);
      }
      expect(tester.takeException(), isNull);
    }
    folds.value = [];
    await tester.pumpAndSettle();
    expect(tester.getRect(find.byType(InteractiveViewer)), initialViewport);
    expect(controller.value, transform);
    expect(find.byTooltip('Close'), findsOneWidget);
    await tester.dragFrom(
      initialViewport.topLeft + const Offset(100, 100),
      const Offset(-50, 0),
    );
    await tester.pumpAndSettle();
    expect(controller.value, isNot(transform));
  });

  testWidgets('map labels stay inside their viewport beside navigation', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(600, 500);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    const captureKey = ValueKey('map-paint-boundary');
    const outsideColor = Color(0xFFEC18BC);
    await _openMap(
      tester,
      home: const RepaintBoundary(
        key: captureKey,
        child: ColoredBox(
          color: outsideColor,
          child: Align(
            alignment: Alignment.centerLeft,
            child: SizedBox(width: 280, child: VenueMapPage()),
          ),
        ),
      ),
    );

    final boundary = tester.renderObject<RenderRepaintBoundary>(
      find.byKey(captureKey),
    );
    final pixels = await tester.runAsync(() async {
      final image = await boundary.toImage(pixelRatio: 1);
      try {
        return await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      } finally {
        image.dispose();
      }
    });
    var paintedOutsideMap = 0;
    for (var y = 56; y < 500; y++) {
      for (var x = 280; x < 600; x++) {
        final offset = (y * 600 + x) * 4;
        if (pixels!.getUint8(offset) != 0xEC ||
            pixels.getUint8(offset + 1) != 0x18 ||
            pixels.getUint8(offset + 2) != 0xBC) {
          paintedOutsideMap++;
        }
      }
    }
    expect(paintedOutsideMap, 0);

    final beforePan = _controller(tester).value.clone();
    await tester.drag(find.byType(InteractiveViewer), const Offset(-50, 0));
    await tester.pumpAndSettle();
    expect(_controller(tester).value, isNot(beforePan));
    expect(tester.takeException(), isNull);
  });

  testWidgets('map keeps selected venue, focal point and zoom while resizing', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(420, 800);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await _openMap(tester);

    await tester.tap(find.bySemanticsLabel(_venue.displayName));
    await tester.pumpAndSettle();
    final controller = _controller(tester);
    final scale = controller.value.getMaxScaleOnAxis();
    final center = _mapCenter(tester);
    expect(find.byTooltip('Close'), findsOneWidget);

    for (final size in [
      const Size(900, 500),
      const Size(520, 700),
      const Size(420, 800),
    ]) {
      tester.view.physicalSize = size;
      await tester.pumpAndSettle();
      expect(_controller(tester), same(controller));
      expect(controller.value.getMaxScaleOnAxis(), closeTo(scale, 0.001));
      expect((_mapCenter(tester) - center).distance, lessThan(0.001));
      expect(find.byTooltip('Close'), findsOneWidget);
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('large text venue details scroll in a narrow short window', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(300, 340);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await _openMap(tester, textScale: 3);
    await tester.tap(find.bySemanticsLabel(_venue.displayName));
    await tester.pumpAndSettle();

    final details = find.byKey(const ValueKey('venue-info-gaming'));
    final scrollable = find.descendant(
      of: details,
      matching: find.byType(Scrollable),
    );
    expect(
      tester.state<ScrollableState>(scrollable).position.maxScrollExtent,
      greaterThan(0),
    );
    expect(
      tester
          .getRect(find.byTooltip('Overview'))
          .overlaps(tester.getRect(details)),
      isFalse,
    );
    expect(find.byTooltip('Close').hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.drag(details, const Offset(0, -120));
    await tester.pumpAndSettle();
    expect(
      tester.state<ScrollableState>(scrollable).position.pixels,
      greaterThan(0),
    );
    expect(tester.takeException(), isNull);
  });
}
