import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app_navigation.dart';
import 'features/info/info_page.dart';
import 'features/map/venue_map_page.dart';
import 'features/schedule/schedule_page.dart';
import 'services/apple_layout.dart';
import 'theme/poc_theme.dart';
import 'theme/reduced_motion_transitions.dart';
import 'widgets/adaptive_navigation.dart';
import 'widgets/accessibility_preferences.dart';
import 'widgets/apple_layout_boundary.dart';

class PlayOnConApp extends ConsumerWidget {
  const PlayOnConApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final layout =
        ref.watch(appleLayoutProvider).valueOrNull ??
        const AppleLayout.unavailable();
    return MaterialApp(
      title: 'Play On Con',
      debugShowCheckedModeBanner: false,
      theme: PocTheme.light(),
      darkTheme: PocTheme.dark(),
      themeMode: ThemeMode.system,
      builder: (context, child) => AccessibilityPreferences(
        child: Builder(
          builder: (context) {
            final theme = Theme.of(context);
            return Theme(
              data: MediaQuery.disableAnimationsOf(context)
                  ? theme.copyWith(
                      pageTransitionsTheme: reducedMotionTransitions,
                    )
                  : theme,
              child: ColoredBox(
                color: theme.colorScheme.surface,
                child: AppleLayoutBoundary(layout: layout, child: child!),
              ),
            );
          },
        ),
      ),
      home: const RootShell(),
    );
  }
}

class RootShell extends ConsumerStatefulWidget {
  const RootShell({super.key});

  @override
  ConsumerState<RootShell> createState() => _RootShellState();
}

class _RootShellState extends ConsumerState<RootShell> {
  static const _pages = [SchedulePage(), VenueMapPage(), InfoPage()];

  @override
  Widget build(BuildContext context) {
    final index = ref.watch(selectedTabProvider);
    final layout =
        ref.watch(appleLayoutProvider).valueOrNull ??
        const AppleLayout.unavailable();
    return AdaptiveNavigationScaffold(
      barEdge: layout.barEdge,
      selectedIndex: index,
      onDestinationSelected: (i) =>
          ref.read(selectedTabProvider.notifier).set(i),
      pages: _pages,
    );
  }
}
