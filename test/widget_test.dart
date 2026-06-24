import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:playoncon/app.dart';
import 'package:playoncon/app_navigation.dart';
import 'package:playoncon/services/last_tab_store.dart';

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
}
