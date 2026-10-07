import 'dart:ui' show SemanticsAction, Tristate;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderParagraph;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:playoncon/features/info/info_page.dart';
import 'package:playoncon/features/schedule/attribute_pill.dart';
import 'package:playoncon/features/schedule/event_detail_page.dart';
import 'package:playoncon/features/schedule/save_event_action.dart';
import 'package:playoncon/features/schedule/schedule_page.dart';
import 'package:playoncon/models/event.dart';
import 'package:playoncon/services/app_clock.dart';
import 'package:playoncon/services/network_monitor.dart';
import 'package:playoncon/services/notification_service.dart';
import 'package:playoncon/services/saved_events_store.dart';
import 'package:playoncon/services/schedule_repository.dart';
import 'package:playoncon/theme/poc_theme.dart';

final _event = Event(
  id: 'accessible-session',
  title: 'Sensory games',
  startTime: DateTime(2026, 7, 9, 16),
  endTime: DateTime(2026, 7, 9, 17),
  locationKey: 'gaming',
  locationDisplayName: 'Main Gaming',
  track: 'Apprentice',
  presenter: 'Casey',
  attributes: const ['SF', 'AT'],
  subSchedule: [
    ScheduleItem(label: 'Learn to play', time: DateTime(2026, 7, 9, 16)),
  ],
);
final _otherEvent = Event(
  id: 'other-session',
  title: 'Board games',
  startTime: DateTime(2026, 7, 9, 17),
  endTime: DateTime(2026, 7, 9, 18),
);

class _Schedule extends ScheduleRepository {
  _Schedule(super.ref, {String? error}) {
    state = ScheduleState(events: [_event, _otherEvent], errorMessage: error);
  }
}

class _Saved extends SavedEventsStore {
  @override
  void save(String id, Reminder reminder) => state = {...state, id: reminder};

  @override
  void remove(String id) => state = Map.of(state)..remove(id);
}

class _LastCustom extends LastCustomReminderStore {
  @override
  Future<void> set(int minutes) async => state = minutes;
}

class _Notifications extends NotificationService {
  Reminder? scheduled;

  @override
  Future<bool> requestPermission() async => true;

  @override
  Future<void> schedule(Event event, Reminder reminder) async {
    scheduled = reminder;
  }

  @override
  Future<void> cancel(String eventId) async {}
}

Widget _app(
  Widget page, {
  _Saved? saved,
  _Notifications? notifications,
  bool dark = false,
  bool reduceMotion = false,
  double textScale = 1,
  String? error,
}) => ProviderScope(
  overrides: [
    scheduleRepositoryProvider.overrideWith(
      (ref) => _Schedule(ref, error: error),
    ),
    savedEventsProvider.overrideWith((_) => saved ?? _Saved()),
    lastCustomReminderProvider.overrideWith((_) => _LastCustom()),
    notificationServiceProvider.overrideWithValue(
      notifications ?? _Notifications(),
    ),
    appClockProvider.overrideWithValue(() => DateTime(2026, 7, 8)),
    connectivityProvider.overrideWith(
      (_) => Stream.value(const NetworkStatus(true)),
    ),
  ],
  child: MaterialApp(
    theme: dark ? PocTheme.dark() : PocTheme.light(),
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context).copyWith(
        textScaler: TextScaler.linear(textScale),
        disableAnimations: reduceMotion,
      ),
      child: child!,
    ),
    home: page,
  ),
);

Widget _savePage() => Consumer(
  builder: (context, ref, _) => Scaffold(
    body: Center(
      child: FilledButton(
        onPressed: () => toggleSaved(context, ref, _event),
        child: const Text('Save'),
      ),
    ),
  ),
);

void main() {
  testWidgets(
    'attribute badges announce their meaning without emoji or codes',
    (tester) async {
      final semantics = tester.ensureSemantics();
      await tester.pumpWidget(
        _app(const Scaffold(body: AttributePillRow(codes: ['SF', 'AT', 'OG']))),
      );
      expect(find.bySemanticsLabel('Sensory Friendly'), findsOneWidget);
      expect(find.bySemanticsLabel('Apprentice Track'), findsOneWidget);
      expect(find.bySemanticsLabel('Sign up at Open Gaming'), findsOneWidget);
      expect(find.bySemanticsLabel('🎧 SF'), findsNothing);
      semantics.dispose();
    },
  );

  testWidgets('each save control names its session and exposes saved state', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    final saved = _Saved();
    await tester.pumpWidget(_app(const SchedulePage(), saved: saved));
    await tester.pumpAndSettle();
    expect(
      find.byTooltip('Save to My Schedule: Sensory games'),
      findsOneWidget,
    );
    expect(find.byTooltip('Save to My Schedule: Board games'), findsOneWidget);
    await tester.tap(find.byTooltip('Save to My Schedule: Sensory games'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('No reminder'));
    await tester.pumpAndSettle();
    expect(saved.isSaved(_event.id), isTrue);
    expect(
      tester
          .getSemantics(
            find.byTooltip('Remove from My Schedule: Sensory games'),
          )
          .flagsCollection
          .isSelected,
      Tristate.isTrue,
    );
    await tester.tap(find.byTooltip('Remove from My Schedule: Sensory games'));
    await tester.pumpAndSettle();
    expect(saved.isSaved(_event.id), isFalse);
    semantics.dispose();
  });

  testWidgets('date and detail headings support screen-reader navigation', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(_app(const SchedulePage()));
    await tester.pumpAndSettle();
    expect(
      tester
          .getSemantics(find.text('Thursday, July 9'))
          .flagsCollection
          .isHeader,
      isTrue,
    );
    await tester.pumpWidget(_app(EventDetailPage(event: _event)));
    await tester.pumpAndSettle();
    expect(
      tester
          .getSemantics(find.text('Sensory games').last)
          .flagsCollection
          .isHeader,
      isTrue,
    );
    expect(
      tester.getSemantics(find.text('Schedule')).flagsCollection.isHeader,
      isTrue,
    );
    expect(find.bySemanticsLabel('Location: Main Gaming'), findsOneWidget);
    expect(find.bySemanticsLabel('Track: Apprentice'), findsOneWidget);
    expect(find.bySemanticsLabel('Presenter: Casey'), findsOneWidget);
    semantics.dispose();
  });

  testWidgets('sync errors announce changes as a live region', (tester) async {
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(
      _app(const SchedulePage(), error: 'Connection lost'),
    );
    await tester.pumpAndSettle();
    expect(
      tester
          .getSemantics(find.text('Sync error: Connection lost'))
          .flagsCollection
          .isLiveRegion,
      isTrue,
    );
    semantics.dispose();
  });

  testWidgets('custom reminders accept typed minutes and validate the range', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    final notifications = _Notifications();
    await tester.pumpWidget(
      _app(_savePage(), notifications: notifications, dark: true),
    );
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Custom…'));
    await tester.pumpAndSettle();
    expect(find.bySemanticsLabel(RegExp('15 minutes before')), findsWidgets);
    final picker = tester.widget<CupertinoPicker>(find.byType(CupertinoPicker));
    expect(picker.backgroundColor, PocTheme.dark().colorScheme.surface);
    await tester.enterText(find.byType(TextField), '121');
    await tester.pumpAndSettle();
    expect(find.text('Enter 1 to 120 minutes'), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(
            find.widgetWithText(FilledButton, 'Set reminder'),
          )
          .onPressed,
      isNull,
    );
    await tester.enterText(find.byType(TextField), '25');
    await tester.pumpAndSettle();
    expect(picker.scrollController!.selectedItem, 24);
    await tester.ensureVisible(find.text('Set reminder'));
    await tester.tap(find.text('Set reminder'));
    await tester.pumpAndSettle();
    expect(notifications.scheduled?.leadMinutes, 25);
    expect(tester.takeException(), isNull);
    semantics.dispose();
  });

  testWidgets(
    'cancel is explicit and reduced motion removes modal transitions',
    (tester) async {
      final semantics = tester.ensureSemantics();
      final saved = _Saved();
      await tester.pumpWidget(
        _app(_savePage(), saved: saved, reduceMotion: true),
      );
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      for (final label in [
        'Custom…',
        'At start time',
        'No reminder',
        'Cancel',
      ]) {
        final node = tester.getSemantics(find.text(label));
        expect(node.flagsCollection.isButton, isTrue, reason: label);
        expect(
          node.getSemanticsData().hasAction(SemanticsAction.tap),
          isTrue,
          reason: label,
        );
      }
      expect(
        tester
            .getSize(find.widgetWithText(SimpleDialogOption, 'Cancel'))
            .height,
        greaterThanOrEqualTo(44),
      );
      expect(
        ModalRoute.of(
          tester.element(find.byType(SimpleDialog)),
        )!.transitionDuration,
        Duration.zero,
      );
      await tester.tap(find.text('Custom…'));
      await tester.pumpAndSettle();
      expect(
        ModalRoute.of(
          tester.element(find.byType(CupertinoPicker)),
        )!.transitionDuration,
        Duration.zero,
      );
      await tester.ensureVisible(find.text('Cancel').last);
      await tester.tap(find.text('Cancel').last);
      await tester.pumpAndSettle();
      expect(find.byType(SimpleDialog), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(saved.isSaved(_event.id), isFalse);
      semantics.dispose();
    },
  );

  testWidgets('schedule tab controller honors the motion preference', (
    tester,
  ) async {
    await tester.pumpWidget(_app(const SchedulePage(), reduceMotion: true));
    await tester.pumpAndSettle();
    expect(
      DefaultTabController.of(
        tester.element(find.byType(TabBar)),
      ).animationDuration,
      Duration.zero,
    );
    await tester.pumpWidget(_app(const SchedulePage(), reduceMotion: false));
    await tester.pumpAndSettle();
    expect(
      DefaultTabController.of(
        tester.element(find.byType(TabBar)),
      ).animationDuration,
      kTabScrollDuration,
    );
  });

  testWidgets(
    'large schedule tabs show full labels and scroll to My Schedule',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(320, 640);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      await tester.pumpWidget(_app(const SchedulePage(), textScale: 3.5));
      await tester.pumpAndSettle();
      final tabs = tester.widget<TabBar>(find.byType(TabBar));
      expect(tabs.isScrollable, isTrue);
      expect(tabs.tabAlignment, TabAlignment.start);
      expect(tester.getSize(find.byType(TabBar)).height, greaterThan(46));
      for (final label in ['All Sessions', 'My Schedule']) {
        final paragraph = tester.renderObject<RenderParagraph>(
          find.text(label),
        );
        expect(paragraph.didExceedMaxLines, isFalse, reason: label);
        expect(
          paragraph.size.width,
          closeTo(paragraph.getMaxIntrinsicWidth(double.infinity), .1),
          reason: label,
        );
      }
      await tester.ensureVisible(find.text('My Schedule'));
      await tester.pumpAndSettle();
      expect(find.text('My Schedule').hitTestable(), findsOneWidget);
      await tester.tap(find.text('My Schedule'));
      await tester.pumpAndSettle();
      expect(
        DefaultTabController.of(tester.element(find.byType(TabBar))).index,
        1,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('typed reminders remain operable above a keyboard at 200% text', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(320, 640);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetViewInsets);
    final saved = _Saved();
    final notifications = _Notifications();
    await tester.pumpWidget(
      _app(
        _savePage(),
        saved: saved,
        notifications: notifications,
        textScale: 2,
      ),
    );
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Custom…'));
    await tester.pumpAndSettle();
    tester.view.viewInsets = const FakeViewPadding(bottom: 300);
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byType(TextField));
    await tester.enterText(find.byType(TextField), '25');
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Cancel').last);
    await tester.pumpAndSettle();
    expect(
      tester.getRect(find.text('Cancel').last).bottom,
      lessThanOrEqualTo(340),
    );
    expect(find.text('Cancel').last.hitTestable(), findsOneWidget);
    await tester.ensureVisible(find.text('Set reminder'));
    await tester.pumpAndSettle();
    expect(
      tester.getRect(find.text('Set reminder')).bottom,
      lessThanOrEqualTo(340),
    );
    expect(find.text('Set reminder').hitTestable(), findsOneWidget);
    await tester.tap(find.text('Set reminder'));
    await tester.pumpAndSettle();
    expect(notifications.scheduled?.leadMinutes, 25);
    expect(saved.isSaved(_event.id), isTrue);

    saved.remove(_event.id);
    tester.view.resetViewInsets();
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Custom…'));
    await tester.pumpAndSettle();
    tester.view.viewInsets = const FakeViewPadding(bottom: 300);
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byType(TextField));
    await tester.enterText(find.byType(TextField), '30');
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Cancel').last);
    await tester.pumpAndSettle();
    expect(
      tester.getRect(find.text('Cancel').last).bottom,
      lessThanOrEqualTo(340),
    );
    await tester.tap(find.text('Cancel').last);
    await tester.pumpAndSettle();
    expect(find.byType(CupertinoPicker), findsNothing);
    tester.view.resetViewInsets();
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Cancel'));
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(saved.isSaved(_event.id), isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('schedule beta badge uses the contrasting app bar foreground', (
    tester,
  ) async {
    for (final dark in [false, true]) {
      await tester.pumpWidget(_app(const SchedulePage(), dark: dark));
      await tester.pumpAndSettle();
      final badge = tester.widget<Text>(find.text('BETA'));
      final theme = Theme.of(tester.element(find.byType(BetaPill)));
      expect(badge.style?.color, theme.appBarTheme.foregroundColor);
    }
  });
}
