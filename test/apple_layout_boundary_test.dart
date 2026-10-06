import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:playoncon/services/apple_layout.dart';
import 'package:playoncon/widgets/apple_layout_boundary.dart';

void main() {
  const viewport = Size(800, 600);
  const contentKey = ValueKey('boundary-content');

  void configureView(WidgetTester tester) {
    tester.view.physicalSize = viewport;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  Future<void> pumpBoundary(
    WidgetTester tester, {
    required AppleLayout layout,
    MediaQueryData media = const MediaQueryData(size: viewport),
    TextDirection direction = TextDirection.ltr,
    bool safeArea = false,
  }) async {
    const content = SizedBox.expand(key: contentKey);
    await tester.pumpWidget(
      Directionality(
        textDirection: direction,
        child: MediaQuery(
          data: media,
          child: AppleLayoutBoundary(
            layout: layout,
            child: safeArea ? const SafeArea(child: content) : content,
          ),
        ),
      ),
    );
  }

  testWidgets('camera clearance unions with safe areas without double insets', (
    tester,
  ) async {
    configureView(tester);
    await pumpBoundary(
      tester,
      direction: TextDirection.rtl,
      safeArea: true,
      media: const MediaQueryData(
        size: viewport,
        padding: EdgeInsets.fromLTRB(40, 24, 20, 34),
        viewPadding: EdgeInsets.fromLTRB(40, 24, 20, 34),
      ),
      layout: const AppleLayout(
        barEdge: AppleBarEdge.right,
        viewSize: viewport,
        occlusions: [
          // Entirely inside existing left safe area; no additional inset.
          Rect.fromLTWH(0, 240, 30, 60),
          // Right camera needs 60 total, rather than 20 + 60.
          Rect.fromLTWH(740, 240, 60, 60),
        ],
      ),
    );
    expect(
      tester.getRect(find.byKey(contentKey)),
      const Rect.fromLTRB(40, 24, 740, 566),
    );
    final inner = MediaQuery.of(tester.element(find.byKey(contentKey)));
    expect(inner.padding, EdgeInsets.zero);
    expect(tester.takeException(), isNull);
  });

  testWidgets('old viewport regions are ignored during a display transition', (
    tester,
  ) async {
    configureView(tester);
    await pumpBoundary(
      tester,
      layout: const AppleLayout(
        barEdge: AppleBarEdge.left,
        viewSize: Size(900, 600),
        occlusions: [Rect.fromLTWH(0, 0, 100, 40)],
        divisions: [Rect.fromLTWH(300, 0, 20, 600)],
      ),
    );
    expect(tester.getRect(find.byKey(contentKey)), Offset.zero & viewport);
    final inner = MediaQuery.of(tester.element(find.byKey(contentKey)));
    expect(inner.padding, EdgeInsets.zero);
    expect(inner.displayFeatures, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('vertical fold retains full width in both text directions', (
    tester,
  ) async {
    configureView(tester);
    for (final direction in TextDirection.values) {
      await pumpBoundary(
        tester,
        direction: direction,
        layout: const AppleLayout(
          barEdge: AppleBarEdge.right,
          viewSize: viewport,
          // An active crease can divide content without hiding any pixels.
          divisions: [Rect.fromLTWH(400, 0, 0, 600)],
        ),
      );
      expect(tester.getRect(find.byKey(contentKey)), Offset.zero & viewport);
      final media = MediaQuery.of(tester.element(find.byKey(contentKey)));
      expect(
        media.displayFeatures.single.bounds,
        const Rect.fromLTWH(400, 0, 0, 600),
      );
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets(
    'horizontal fold retains full height and exposes the crease to overlays',
    (tester) async {
      configureView(tester);
      await pumpBoundary(
        tester,
        layout: const AppleLayout(
          barEdge: AppleBarEdge.none,
          viewSize: viewport,
          divisions: [Rect.fromLTWH(0, 200, 800, 20)],
        ),
      );
      expect(tester.getRect(find.byKey(contentKey)), Offset.zero & viewport);
      final media = MediaQuery.of(tester.element(find.byKey(contentKey)));
      expect(
        media.displayFeatures.single.bounds,
        const Rect.fromLTWH(0, 200, 800, 20),
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'only open dialogs and sheets move aside when the display folds',
    (tester) async {
      configureView(tester);
      final layout = ValueNotifier(
        const AppleLayout(barEdge: AppleBarEdge.right, viewSize: viewport),
      );
      addTearDown(layout.dispose);
      final navigator = GlobalKey<NavigatorState>();
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: navigator,
          builder: (context, child) => ValueListenableBuilder(
            valueListenable: layout,
            child: child,
            builder: (context, value, child) =>
                AppleLayoutBoundary(layout: value, child: child!),
          ),
          home: const Scaffold(body: SizedBox.expand(key: contentKey)),
        ),
      );
      final context = tester.element(find.byKey(contentKey));
      for (final sheet in [false, true]) {
        layout.value = const AppleLayout(
          barEdge: AppleBarEdge.right,
          viewSize: viewport,
        );
        await tester.pumpAndSettle();
        const overlayKey = ValueKey('fold-overlay');
        if (sheet) {
          showModalBottomSheet<void>(
            context: context,
            builder: (_) => const SizedBox(
              key: overlayKey,
              width: double.infinity,
              height: 160,
            ),
          );
        } else {
          showDialog<void>(
            context: context,
            builder: (_) => const SimpleDialog(
              key: overlayKey,
              title: Text('Add a reminder?'),
              children: [Text('No reminder')],
            ),
          );
        }
        await tester.pumpAndSettle();
        final overlay = tester.element(find.byKey(overlayKey));
        for (final crease in const [
          Rect.fromLTWH(390, 0, 20, 600),
          Rect.fromLTWH(0, 290, 800, 20),
        ]) {
          layout.value = AppleLayout(
            barEdge: AppleBarEdge.right,
            viewSize: viewport,
            divisions: [crease],
          );
          await tester.pumpAndSettle();
          expect(
            tester.getRect(find.byKey(contentKey, skipOffstage: false)),
            Offset.zero & viewport,
          );
          expect(
            tester.getRect(find.byKey(overlayKey)).overlaps(crease),
            isFalse,
          );
          expect(tester.element(find.byKey(overlayKey)), same(overlay));
          expect(tester.takeException(), isNull);
        }
        navigator.currentState!.pop();
        await tester.pumpAndSettle();
      }
    },
  );

  testWidgets('an open route retains input and focus through fold changes', (
    tester,
  ) async {
    configureView(tester);
    final layout = ValueNotifier(
      const AppleLayout(barEdge: AppleBarEdge.none, viewSize: viewport),
    );
    addTearDown(layout.dispose);
    final navigatorKey = GlobalKey<NavigatorState>();
    final textController = TextEditingController();
    final focus = FocusNode();
    addTearDown(textController.dispose);
    addTearDown(focus.dispose);
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigatorKey,
        builder: (context, child) => ValueListenableBuilder(
          valueListenable: layout,
          child: child,
          builder: (context, value, child) =>
              AppleLayoutBoundary(layout: value, child: child!),
        ),
        home: const Scaffold(body: Text('Schedule root')),
      ),
    );
    navigatorKey.currentState!.push<void>(
      MaterialPageRoute(
        builder: (_) => Scaffold(
          appBar: AppBar(title: const Text('Open detail')),
          body: TextField(controller: textController, focusNode: focus),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Werewolf notes');
    focus.requestFocus();
    await tester.pump();
    final routeState = tester.state(find.byType(TextField));
    final navigatorState = navigatorKey.currentState;
    for (final next in const [
      AppleLayout(
        barEdge: AppleBarEdge.right,
        viewSize: viewport,
        divisions: [Rect.fromLTWH(390, 0, 20, 600)],
      ),
      AppleLayout(
        barEdge: AppleBarEdge.none,
        viewSize: viewport,
        divisions: [Rect.fromLTWH(0, 200, 800, 20)],
      ),
      AppleLayout(barEdge: AppleBarEdge.none, viewSize: viewport),
    ]) {
      layout.value = next;
      await tester.pumpAndSettle();
      expect(navigatorKey.currentState, same(navigatorState));
      expect(tester.state(find.byType(TextField)), same(routeState));
      expect(textController.text, 'Werewolf notes');
      expect(focus.hasFocus, isTrue);
      expect(find.text('Open detail'), findsOneWidget);
      expect(tester.takeException(), isNull);
    }
    navigatorKey.currentState!.pop();
    await tester.pumpAndSettle();
    expect(find.text('Schedule root'), findsOneWidget);
  });
}
