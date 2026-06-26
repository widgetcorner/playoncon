import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'app.dart';
import 'app_navigation.dart';
import 'config/app_config.dart';
import 'services/last_tab_store.dart';
import 'services/notification_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final notifications = NotificationService();
  await notifications.init();
  // Supabase is optional: it powers the live cart layer on the venue map.
  // Without it the rest of the app (schedule, map, info) still works offline.
  if (AppConfig.hasSupabaseConfig) {
    try {
      await Supabase.initialize(
        url: AppConfig.supabaseUrl,
        publishableKey: AppConfig.supabasePublishableKey,
      );
    } catch (e) {
      debugPrint('Supabase.initialize failed; cart layer disabled: $e');
    }
  }
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
