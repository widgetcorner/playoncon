import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app.dart';
import 'app_navigation.dart';
import 'services/last_tab_store.dart';
import 'services/notification_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final notifications = NotificationService();
  await notifications.init();
  final initialTab = await LastTabStore.loadInitial();
  runApp(
    ProviderScope(
      overrides: [
        notificationServiceProvider.overrideWithValue(notifications),
        selectedTabProvider
            .overrideWith((_) => LastTabStore(initialTab)),
      ],
      child: const PlayOnConApp(),
    ),
  );
}
