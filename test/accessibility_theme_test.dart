import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:playoncon/app.dart';
import 'package:playoncon/app_navigation.dart';
import 'package:playoncon/services/last_tab_store.dart';
import 'package:playoncon/theme/poc_theme.dart';
import 'package:playoncon/widgets/accessible_progress_indicator.dart';

double _contrast(Color foreground, Color background) {
  final visible = Color.alphaBlend(foreground, background);
  final a = visible.computeLuminance();
  final b = background.computeLuminance();
  return (a > b ? a + 0.05 : b + 0.05) / (a > b ? b + 0.05 : a + 0.05);
}

void main() {
  for (final theme in [PocTheme.light(), PocTheme.dark()]) {
    test('${theme.brightness.name} text and control contrast', () {
      final scheme = theme.colorScheme;
      final pal = theme.extension<PocPalette>()!;
      final textPairs = <String, (Color, Color)>{
        'body': (scheme.onSurface, scheme.surface),
        'secondary text': (pal.textSoft, scheme.surface),
        'day heading': (
          scheme.onSurfaceVariant,
          scheme.surfaceContainerHighest,
        ),
        'primary button': (scheme.onPrimary, scheme.primary),
        'secondary button': (scheme.onSecondary, scheme.secondary),
        'tertiary button': (scheme.onTertiary, scheme.tertiary),
        'error': (scheme.onErrorContainer, scheme.errorContainer),
        'app bar': (
          theme.appBarTheme.foregroundColor!,
          theme.appBarTheme.backgroundColor!,
        ),
        'app bar beta badge': (
          theme.appBarTheme.foregroundColor!,
          Color.alphaBlend(
            theme.appBarTheme.foregroundColor!.withValues(alpha: 0.1),
            theme.appBarTheme.backgroundColor!,
          ),
        ),
        'selected tab': (
          theme.tabBarTheme.labelColor!,
          theme.appBarTheme.backgroundColor!,
        ),
        'unselected tab': (
          theme.tabBarTheme.unselectedLabelColor!,
          theme.appBarTheme.backgroundColor!,
        ),
        'attribute pill': (pal.pillText, pal.pillBackground),
        'venue detail': (scheme.onSurface, pal.sheetSurface),
        'venue description': (pal.textSoft, pal.sheetSurface),
        'map label': (pal.labelChipText, pal.sheetSurface),
      };
      for (final entry in textPairs.entries) {
        expect(
          _contrast(entry.value.$1, entry.value.$2),
          greaterThanOrEqualTo(4.5),
          reason: '${theme.brightness.name}: ${entry.key}',
        );
      }
      for (final background in [
        scheme.surface,
        scheme.surfaceContainerHighest,
      ]) {
        expect(_contrast(scheme.outline, background), greaterThanOrEqualTo(3));
      }
      expect(
        _contrast(pal.controlIcon, pal.controlSurface),
        greaterThanOrEqualTo(3),
      );
      expect(
        _contrast(pal.fabForeground, pal.fabBackground),
        greaterThanOrEqualTo(3),
      );
      for (final states in [
        <WidgetState>{},
        {WidgetState.selected},
      ]) {
        final foreground = theme.navigationBarTheme.labelTextStyle!
            .resolve(states)!
            .color!;
        expect(
          _contrast(foreground, theme.navigationBarTheme.backgroundColor!),
          greaterThanOrEqualTo(4.5),
        );
      }
    });
  }

  testWidgets(
    'Reduce Motion replaces continuous loading with named still feedback',
    (tester) async {
      final semantics = tester.ensureSemantics();
      final reduce = ValueNotifier(false);
      addTearDown(reduce.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: ValueListenableBuilder<bool>(
            valueListenable: reduce,
            builder: (context, value, _) => MediaQuery(
              data: MediaQuery.of(context).copyWith(disableAnimations: value),
              child: const Scaffold(
                body: Center(
                  child: AccessibleProgressIndicator(
                    label: 'Refreshing schedule',
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      reduce.value = true;
      await tester.pumpAndSettle();
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.byIcon(Icons.hourglass_empty), findsOneWidget);
      expect(find.bySemanticsLabel('Refreshing schedule'), findsOneWidget);
      expect(tester.binding.transientCallbackCount, 0);
      semantics.dispose();
    },
  );

  testWidgets(
    'Reduce Motion removes page movement and restores platform transitions',
    (tester) async {
      // Apple's flag is distinct from Android's disableAnimations flag.
      tester.platformDispatcher.accessibilityFeaturesTestValue =
          const FakeAccessibilityFeatures(reduceMotion: true);
      addTearDown(
        tester.platformDispatcher.clearAccessibilityFeaturesTestValue,
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [selectedTabProvider.overrideWith((_) => LastTabStore(0))],
          child: const PlayOnConApp(),
        ),
      );
      await tester.pump();
      final context = tester.element(find.byType(NavigationBar));
      final theme = Theme.of(context);
      final transition = theme.pageTransitionsTheme.builders[theme.platform]!;
      expect(transition.transitionDuration, Duration.zero);
      expect(transition.reverseTransitionDuration, Duration.zero);
      expect(transition.delegatedTransition, isNull);

      final navigator = Navigator.of(context);
      final route = MaterialPageRoute<void>(
        builder: (_) => const Scaffold(body: Text('Accessible detail')),
      );
      navigator.push(route);
      await tester.pump();
      await tester.pump();
      expect(route.transitionDuration, Duration.zero);
      expect(find.text('Accessible detail'), findsOneWidget);
      navigator.pop();
      await tester.pump();
      await tester.pump();

      tester.platformDispatcher.accessibilityFeaturesTestValue =
          const FakeAccessibilityFeatures(reduceMotion: false);
      await tester.pump();
      final restored = Theme.of(tester.element(find.byType(NavigationBar)));
      expect(
        restored
            .pageTransitionsTheme
            .builders[restored.platform]!
            .transitionDuration,
        greaterThan(Duration.zero),
      );
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
