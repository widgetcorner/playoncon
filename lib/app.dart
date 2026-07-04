import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app_navigation.dart';
import 'features/info/info_page.dart';
import 'features/map/venue_map_page.dart';
import 'features/schedule/schedule_page.dart';
import 'theme/poc_theme.dart';

class PlayOnConApp extends StatelessWidget {
  const PlayOnConApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Play On Con',
      theme: PocTheme.light(),
      darkTheme: PocTheme.dark(),
      themeMode: ThemeMode.system,
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
  static const _pages = [
    SchedulePage(),
    VenueMapPage(),
    InfoPage(),
  ];

  @override
  Widget build(BuildContext context) {
    final index = ref.watch(selectedTabProvider);
    return Scaffold(
      body: IndexedStack(index: index, children: _pages),
      bottomNavigationBar: NavigationBar(
        selectedIndex: index,
        onDestinationSelected: (i) =>
            ref.read(selectedTabProvider.notifier).set(i),
        destinations: const [
          NavigationDestination(
              icon: Icon(Icons.calendar_month), label: 'Schedule'),
          NavigationDestination(icon: Icon(Icons.map), label: 'Map'),
          NavigationDestination(icon: Icon(Icons.info_outline), label: 'Info'),
        ],
      ),
    );
  }
}
