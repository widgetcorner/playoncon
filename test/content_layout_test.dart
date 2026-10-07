import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:playoncon/features/info/contact_page.dart';
import 'package:playoncon/features/info/info_page.dart';
import 'package:playoncon/features/schedule/event_detail_page.dart';
import 'package:playoncon/features/schedule/save_event_action.dart';
import 'package:playoncon/features/schedule/schedule_page.dart';
import 'package:playoncon/models/event.dart';
import 'package:playoncon/services/apple_layout.dart';
import 'package:playoncon/services/network_monitor.dart';
import 'package:playoncon/services/notification_service.dart';
import 'package:playoncon/services/saved_events_store.dart';
import 'package:playoncon/services/schedule_repository.dart';
import 'package:playoncon/theme/poc_theme.dart';
import 'package:playoncon/widgets/apple_layout_boundary.dart';

final _event = Event(
  id: 'layout-test',
  title: 'A long session title that needs room to wrap on the outer display',
  startTime: DateTime(2026, 7, 9, 16),
  endTime: DateTime(2026, 7, 9, 18),
  locationKey: 'gaming',
  locationDisplayName: 'Video Gaming (Gaming Building Classroom 2)',
  details: 'A full event description that remains readable after resizing.',
  attributes: const ['SF', 'AT', 'OG'],
);

class _Schedule extends ScheduleRepository {
  _Schedule(super.ref) {
    state = ScheduleState(events: [_event]);
  }
}

class _Notifications extends NotificationService {
  Reminder? scheduled;

  @override
  Future<bool> requestPermission() async => true;

  @override
  Future<void> schedule(Event event, Reminder reminder) async {
    scheduled = reminder;
  }
}

Widget _app(
  Widget page, {
  double textScale = 1,
  _Notifications? notifications,
  ValueNotifier<AppleLayout>? layout,
}) {
  return ProviderScope(
    overrides: [
      scheduleRepositoryProvider.overrideWith(_Schedule.new),
      connectivityProvider.overrideWith(
        (_) => Stream.value(const NetworkStatus(false)),
      ),
      if (notifications != null)
        notificationServiceProvider.overrideWithValue(notifications),
    ],
    child: MaterialApp(
      theme: PocTheme.light(),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(textScale)),
        child: layout == null
            ? child!
            : ValueListenableBuilder<AppleLayout>(
                valueListenable: layout,
                child: child,
                builder: (context, value, child) =>
                    AppleLayoutBoundary(layout: value, child: child!),
              ),
      ),
      home: page,
    ),
  );
}

void main() {
  testWidgets('offline schedule and saved empty state fit narrow large text', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(280, 500);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(_app(const SchedulePage(), textScale: 2.5));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('Offline — showing cached schedule'), findsOneWidget);

    await tester.ensureVisible(find.text('My Schedule'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('My Schedule'));
    await tester.pumpAndSettle();
    tester.view.physicalSize = const Size(600, 320);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(
      DefaultTabController.of(tester.element(find.byType(TabBar))).index,
      1,
    );
  });

  testWidgets('detail remains readable and scrollable across wide and narrow', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1100, 700);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      _app(EventDetailPage(event: _event), textScale: 2.5),
    );
    await tester.pumpAndSettle();
    expect(tester.getSize(find.byType(ListView)).width, 720);
    expect(tester.takeException(), isNull);

    tester.view.physicalSize = const Size(280, 500);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.scrollUntilVisible(
      find.text(_event.details!),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    expect(find.text(_event.details!).hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  for (final page in <Widget>[const InfoPage(), const ContactPage()]) {
    testWidgets(
      '${page.runtimeType} uses readable width and narrow large text',
      (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(1100, 700);
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await tester.pumpWidget(_app(page, textScale: 2.5));
        await tester.pumpAndSettle();
        expect(tester.getSize(find.byType(ListView)).width, 720);
        expect(tester.takeException(), isNull);
        tester.view.physicalSize = const Size(280, 500);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await tester.drag(find.byType(ListView), const Offset(0, -400));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  testWidgets(
    'custom reminder preserves selection and can confirm after resize',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(320, 700);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final notifications = _Notifications();
      await tester.pumpWidget(
        _app(
          Consumer(
            builder: (context, ref, _) => Scaffold(
              body: Center(
                child: FilledButton(
                  onPressed: () => toggleSaved(context, ref, _event),
                  child: const Text('Save'),
                ),
              ),
            ),
          ),
          textScale: 2.5,
          notifications: notifications,
        ),
      );
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('Custom…'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      final controller = tester
          .widget<CupertinoPicker>(find.byType(CupertinoPicker))
          .scrollController!;
      await tester.ensureVisible(find.byType(CupertinoPicker));
      await tester.pumpAndSettle();
      await tester.drag(find.byType(CupertinoPicker), const Offset(0, -140));
      await tester.pumpAndSettle();
      final selected = controller.selectedItem;
      expect(selected, isNot(14));

      tester.view.physicalSize = const Size(480, 280);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(
        tester
            .widget<CupertinoPicker>(find.byType(CupertinoPicker))
            .scrollController,
        same(controller),
      );
      expect(controller.selectedItem, selected);
      await tester.ensureVisible(find.text('Set reminder'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Set reminder'));
      await tester.pumpAndSettle();
      expect(notifications.scheduled?.leadMinutes, selected + 1);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'open reminder and picker avoid both fold axes and retain chosen time',
    (tester) async {
      const viewport = Size(800, 600);
      const underlayKey = ValueKey('reminder-underlay');
      const creases = [
        Rect.fromLTWH(390, 0, 20, 600),
        Rect.fromLTWH(0, 290, 800, 20),
      ];
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = viewport;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final layout = ValueNotifier(
        const AppleLayout(barEdge: AppleBarEdge.none, viewSize: viewport),
      );
      addTearDown(layout.dispose);
      final notifications = _Notifications();
      await tester.pumpWidget(
        _app(
          Consumer(
            builder: (context, ref, _) => Scaffold(
              body: SizedBox.expand(
                key: underlayKey,
                child: Center(
                  child: FilledButton(
                    onPressed: () => toggleSaved(context, ref, _event),
                    child: const Text('Save'),
                  ),
                ),
              ),
            ),
          ),
          layout: layout,
          notifications: notifications,
          textScale: 1.5,
        ),
      );
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      final dialog = tester.element(find.byType(SimpleDialog));
      for (final crease in creases) {
        layout.value = AppleLayout(
          barEdge: AppleBarEdge.none,
          viewSize: viewport,
          divisions: [crease],
        );
        await tester.pumpAndSettle();
        expect(tester.element(find.byType(SimpleDialog)), same(dialog));
        expect(
          tester.getRect(find.byType(SimpleDialog)).overlaps(crease),
          isFalse,
        );
        expect(tester.takeException(), isNull);
      }

      await tester.ensureVisible(find.text('Custom…'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Custom…'));
      await tester.pumpAndSettle();
      final picker = tester.element(find.byType(CupertinoPicker));
      final controller = tester
          .widget<CupertinoPicker>(find.byType(CupertinoPicker))
          .scrollController!;
      await tester.ensureVisible(find.byType(CupertinoPicker));
      await tester.pumpAndSettle();
      await tester.drag(find.byType(CupertinoPicker), const Offset(0, -110));
      await tester.pumpAndSettle();
      final selected = controller.selectedItem;
      expect(selected, isNot(14));

      for (final crease in <Rect?>[null, ...creases]) {
        layout.value = AppleLayout(
          barEdge: AppleBarEdge.none,
          viewSize: viewport,
          divisions: [?crease],
        );
        await tester.pumpAndSettle();
        expect(tester.element(find.byType(CupertinoPicker)), same(picker));
        expect(
          tester
              .widget<CupertinoPicker>(find.byType(CupertinoPicker))
              .scrollController,
          same(controller),
        );
        expect(controller.selectedItem, selected);
        expect(
          tester.getRect(find.byKey(underlayKey, skipOffstage: false)),
          Offset.zero & viewport,
        );
        if (crease != null) {
          expect(
            tester.getRect(find.byType(BottomSheet)).overlaps(crease),
            isFalse,
          );
        }
        expect(tester.takeException(), isNull);
      }
      await tester.ensureVisible(find.text('Set reminder'));
      await tester.pumpAndSettle();
      expect(find.text('Set reminder').hitTestable(), findsOneWidget);
      await tester.tap(find.text('Set reminder'));
      await tester.pumpAndSettle();
      expect(notifications.scheduled?.leadMinutes, selected + 1);
      expect(find.byType(CupertinoPicker), findsNothing);
      expect(find.byType(SimpleDialog), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
}
