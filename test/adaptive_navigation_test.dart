import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:playoncon/services/apple_layout.dart';
import 'package:playoncon/theme/poc_theme.dart';
import 'package:playoncon/widgets/adaptive_navigation.dart';
import 'package:playoncon/widgets/apple_layout_boundary.dart';

void main() {
  testWidgets('native edge changes retain input, selection and mounted pages', (
    tester,
  ) async {
    final edge = ValueNotifier(AppleBarEdge.none);
    final selected = ValueNotifier(0);
    addTearDown(edge.dispose);
    addTearDown(selected.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: PocTheme.light(),
        home: ListenableBuilder(
          listenable: Listenable.merge([edge, selected]),
          builder: (context, _) => AdaptiveNavigationScaffold(
            barEdge: edge.value,
            selectedIndex: selected.value,
            onDestinationSelected: (value) => selected.value = value,
            pages: const [
              Scaffold(body: TextField()),
              Scaffold(body: Text('Map content')),
              Scaffold(body: Text('Info content')),
            ],
          ),
        ),
      ),
    );
    await tester.enterText(find.byType(TextField), 'Werewolf');
    final inputState = tester.state(find.byType(TextField));
    for (final next in [
      AppleBarEdge.left,
      AppleBarEdge.right,
      AppleBarEdge.none,
    ]) {
      edge.value = next;
      await tester.pumpAndSettle();
      expect(tester.state(find.byType(TextField)), same(inputState));
      expect(find.text('Werewolf'), findsOneWidget);
      expect(tester.takeException(), isNull);
    }
    await tester.tap(find.text('Map'));
    await tester.pumpAndSettle();
    edge.value = AppleBarEdge.right;
    await tester.pumpAndSettle();
    expect(selected.value, 1);
    expect(find.text('Map content'), findsOneWidget);
    expect(
      tester.widget<NavigationRail>(find.byType(NavigationRail)).selectedIndex,
      1,
    );
  });

  testWidgets('rail shares the physical system strip in RTL exactly once', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(600, 500);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    for (final edge in [AppleBarEdge.left, AppleBarEdge.right]) {
      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: const MediaQueryData(
              size: Size(600, 500),
              padding: EdgeInsets.fromLTRB(80, 24, 80, 20),
            ),
            child: Directionality(
              textDirection: TextDirection.rtl,
              child: AdaptiveNavigationScaffold(
                barEdge: edge,
                selectedIndex: 0,
                onDestinationSelected: (_) {},
                pages: const [
                  SizedBox.expand(key: ValueKey('content')),
                  SizedBox.expand(),
                  SizedBox.expand(),
                ],
              ),
            ),
          ),
        ),
      );
      final rail = tester.getRect(find.byType(NavigationRail));
      final content = tester.getRect(find.byKey(const ValueKey('content')));
      if (edge == AppleBarEdge.left) {
        expect(rail.left, 0);
        expect(content.left, rail.right);
        expect(content.right, 520);
        expect(tester.getCenter(find.byIcon(Icons.map)).dx, 44);
      } else {
        expect(rail.right, 600);
        expect(content.right, rail.left);
        expect(content.left, 80);
        expect(tester.getCenter(find.byIcon(Icons.map)).dx, 556);
      }
      expect(rail.width, 88);
      expect(content.bottom, 480);
      final innerMedia = MediaQuery.of(
        tester.element(find.byKey(const ValueKey('content'))),
      );
      expect(innerMedia.padding.left, 0);
      expect(innerMedia.padding.right, 0);
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('strip avoids camera while folded content uses both halves', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        theme: PocTheme.light(),
        builder: (context, child) => AppleLayoutBoundary(
          layout: const AppleLayout(
            barEdge: AppleBarEdge.right,
            viewSize: Size(800, 600),
            divisions: [Rect.fromLTWH(390, 0, 20, 600)],
            occlusions: [
              Rect.fromLTWH(720, 0, 80, 150),
              Rect.fromLTWH(740, 510, 60, 90),
            ],
          ),
          child: child!,
        ),
        home: AdaptiveNavigationScaffold(
          barEdge: AppleBarEdge.right,
          selectedIndex: 0,
          onDestinationSelected: (_) {},
          pages: const [
            SizedBox.expand(key: ValueKey('fold-content')),
            SizedBox(),
            SizedBox(),
          ],
        ),
      ),
    );
    final rail = tester.getRect(find.byType(NavigationRail));
    expect(rail.right, 800);
    expect(rail.left, 712);
    expect(rail.top, 150);
    expect(rail.bottom, 510);
    expect(
      tester.getRect(find.byKey(const ValueKey('fold-content'))),
      const Rect.fromLTRB(0, 0, 712, 600),
    );
    for (final icon in [Icons.calendar_month, Icons.map, Icons.info_outline]) {
      final rect = tester.getRect(find.byIcon(icon));
      expect(rect.center.dx, 756);
      expect(rect.top, greaterThanOrEqualTo(150));
      expect(rect.bottom, lessThanOrEqualTo(510));
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'side controls clear a zero-height crease without shrinking page content',
    (tester) async {
      tester.view.physicalSize = const Size(800, 600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => AppleLayoutBoundary(
            layout: const AppleLayout(
              barEdge: AppleBarEdge.right,
              viewSize: Size(800, 600),
              divisions: [Rect.fromLTWH(0, 300, 800, 0)],
            ),
            child: child!,
          ),
          home: AdaptiveNavigationScaffold(
            barEdge: AppleBarEdge.right,
            selectedIndex: 0,
            onDestinationSelected: (_) {},
            pages: const [
              SizedBox.expand(key: ValueKey('full-content')),
              SizedBox(),
              SizedBox(),
            ],
          ),
        ),
      );
      expect(
        tester.getRect(find.byKey(const ValueKey('full-content'))),
        const Rect.fromLTWH(0, 0, 712, 600),
      );
      expect(
        tester.getRect(find.byType(NavigationRail)),
        const Rect.fromLTRB(712, 300, 800, 600),
      );
      for (final icon in [
        Icons.calendar_month,
        Icons.map,
        Icons.info_outline,
      ]) {
        expect(tester.getRect(find.byIcon(icon)).top, greaterThan(300));
      }
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'short rail scrolls to destinations at accessibility text sizes',
    (tester) async {
      tester.view.physicalSize = const Size(320, 220);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      int selected = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: const MediaQueryData(textScaler: TextScaler.linear(3)),
            child: AdaptiveNavigationScaffold(
              barEdge: AppleBarEdge.left,
              selectedIndex: 0,
              onDestinationSelected: (value) => selected = value,
              pages: const [SizedBox(), SizedBox(), SizedBox()],
            ),
          ),
        ),
      );
      await tester.ensureVisible(find.byIcon(Icons.info_outline));
      await tester.tap(find.byIcon(Icons.info_outline));
      await tester.pumpAndSettle();
      expect(selected, 2);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'unsupported and supported-none keep bottom navigation at any width',
    (tester) async {
      tester.view.physicalSize = const Size(1100, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      for (final edge in [AppleBarEdge.unavailable, AppleBarEdge.none]) {
        await tester.pumpWidget(
          MaterialApp(
            home: AdaptiveNavigationScaffold(
              barEdge: edge,
              selectedIndex: 0,
              onDestinationSelected: (_) {},
              pages: const [SizedBox(), SizedBox(), SizedBox()],
            ),
          ),
        );
        expect(find.byType(NavigationBar), findsOneWidget);
        expect(find.byType(NavigationRail), findsNothing);
      }
    },
  );
}
