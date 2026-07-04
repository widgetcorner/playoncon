import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:playoncon/app.dart';
import 'package:playoncon/app_navigation.dart';
import 'package:playoncon/services/last_tab_store.dart';
import 'package:playoncon/theme/poc_theme.dart';

void main() {
  testWidgets('App renders bottom navigation', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          selectedTabProvider.overrideWith((_) => LastTabStore(0)),
        ],
        child: const PlayOnConApp(),
      ),
    );
    await tester.pump();

    expect(find.text('Schedule'), findsWidgets);
    expect(find.text('Map'), findsWidgets);
    expect(find.text('Info'), findsWidgets);
  });

  testWidgets('App follows a dark platform brightness', (tester) async {
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
    addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          selectedTabProvider.overrideWith((_) => LastTabStore(0)),
        ],
        child: const PlayOnConApp(),
      ),
    );
    await tester.pump();

    final context = tester.element(find.byType(NavigationBar));
    final theme = Theme.of(context);
    expect(theme.brightness, Brightness.dark);
    expect(theme.colorScheme.surface, PocColors.pineNight);
    // The PocPalette extension must be registered on the dark theme, or every
    // widget reading PocPalette.of() silently falls back to light colors.
    expect(theme.extension<PocPalette>(), same(PocPalette.dark));
  });
}
