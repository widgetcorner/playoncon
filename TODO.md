# Code review backlog — 2026-07-04

Findings from a full-codebase review, prioritized. Check items off as they land.

## P0 — data-loss shaped bugs

- [x] **Empty parse wipes the schedule cache.** *(fixed 2026-11-12: `EmptyScheduleException`)* Parser guards return `[]` instead of
  throwing (`lib/services/csv_parser.dart:81,97,283,303`; header detection requires a
  literal `theater` column at `:278`/`:594`), and `refresh()` writes the cache
  unconditionally (`lib/services/schedule_repository.dart:145`). A sheet edit that
  breaks parsing (rename "Theater", insert a column, bad gid) overwrites the good
  cache with nothing and reports a successful sync. Guard: throw/skip-write when
  `events.isEmpty` — the error path already preserves stale events.
- [x] **Event IDs use Dart `String.hashCode`, not stable across SDK versions** *(fixed 2026-11-12: `stableEventId` in `stable_hash.dart` — FNV-1a + wall-clock text, which also removes the device-timezone dependence of the old epoch-ms part; bundled schedules re-IDed; no migration of old saves. Reminders now scheduled in America/Chicago.)*
  (`lib/services/csv_parser.dart:759-761`; also `notification_service.dart` `_idFor`).
  An SDK upgrade could orphan every saved event + reminder at once. Replace with a
  fixed in-project hash (e.g. FNV-1a). Do before the con to avoid a migration later.
- [x] **`SavedEventsStore` load/save race** *(fixed 2026-11-12, incl. `LastCustomReminderStore`; `LastTabStore` loads before `runApp` so had no race)* (`lib/services/saved_events_store.dart:59-61,103-106`).
  `_load()` fires unawaited from the constructor; a `save()` landing first persists a
  single-entry map over the whole file. Memoize the load future and await it in
  `save`/`remove`. Same pattern in `LastCustomReminderStore` / `LastTabStore`.
- [x] **Moved sheet events keep firing stale reminders.** *(fixed 2026-11-12: `SavedReconciliation` runs after each successful sync — moved sessions keep their save + reminder, vanished ones are removed and cancelled; skipped when the schedule shrinks >20%)* ID embeds start time, so a
  reschedule orphans the save but nothing cancels the OS notification. Add a
  reconciliation pass on sync: cancel notification IDs no longer in the schedule.

## P1 — user-visible behavior

- [x] **Denied notification permission still shows "Saved with a reminder"** *(fixed 2026-11-12; past fire-times too)*
  (`lib/features/schedule/save_event_action.dart:27-35`). Branch on the
  `requestPermission()` result.
- [x] **GPS stream never stops once enabled.** *(fixed 2026-11-12)* `IndexedStack` (`lib/app.dart:41`) keeps
  the map mounted; `ref.watch(currentPositionProvider)` (`venue_map_page.dart:526`)
  keeps high-accuracy GPS running on other tabs all day. Gate on
  `selectedTabProvider == mapTabIndex`.
- [x] **Pull-to-refresh unreachable from the empty state** *(fixed 2026-11-12)* (`schedule_page.dart:151`
  returns before the `RefreshIndicator`); short lists also need
  `AlwaysScrollableScrollPhysics` so "My Schedule" with 2 items can be pulled.
- [x] **`refresh()` re-entrancy + non-atomic cache writes.** *(fixed 2026-11-12)* `isSyncing` set but never
  checked (`schedule_repository.dart:87-92`); overlapping refreshes can interleave
  `_writeCache`. Add early-return guard + temp-file-then-rename writes (also for
  `saved_events.json`).
- [x] **Map accessibility:** *(already fixed by the 2026.10.7 accessibility pass)* pins have no `Semantics` labels (screen readers get nothing
  on the Map tab, `venue_map_page.dart:1130-1156`); label collision math ignores
  system text scale so 130%+ fonts overlap (`:794-801` — pass
  `MediaQuery.textScalerOf` into the `TextPainter`, flush cache on scale change).

## P2 — structural

- [ ] **Split `venue_map_page.dart` (1,828 lines).** Order of payoff:
  1. debug hotspot editor → own file (~700 lines, removes `_editing` conditionals
     from the shipping path);
  2. letterbox/projection math → one `MapViewportGeometry` (currently duplicated
     verbatim: `_matrixForNormalized` vs `_captureLetterbox`);
  3. pin overlay + collision algorithm → stateless widget (makes it unit-testable);
  4. venue info sheet → self-contained `ConsumerWidget` (fixes stale "Now/Next" and
     stops syncs from rebuilding the whole map);
  5. leaf markers (`_PinIcon`, `_PinLabel`, `_CartMarker`, …) → `map_markers.dart`.
- [x] **Make `ScheduleRepository` testable:** *(2026-11-12: `ScheduleSource` + injectable documents folder; `test/schedule_sync_test.dart`)* inject `http.Client` / client factory
  (pattern `SheetsApiClient` already uses) so merge/cache/error-preservation logic
  can be tested.

## P3 — tests & hygiene

- [x] Tests for `SheetsApiClient.fetchTabs` *(2026-11-12; a requested tab missing from the workbook now fails the fetch)* (injectable client already exists — cheap,
  and it's the production data path).
- [x] Tests for `Event` JSON round-trip (`test/reliability_test.dart`): legacy caches without `attributes`/
  `subSchedule`, and the pre-3AM `dayKey` roll.
- [x] Tests for `SavedEventsStore._load` legacy list format *(2026-11-12)* (`Reminder.fromJsonValue`
  legacy formats are now covered in `test/reliability_test.dart`).
- [x] Extract notification fire-time math to a pure function and test the
  past-fire skip. (`NotificationService.fireTime`)
- [x] Enable `strict-casts` *(2026-11-12: zero findings; `unawaited_futures` found 3, all intentional → `unawaited`)* (heavy dynamic JSON handling) + `unawaited_futures` in
  `analysis_options.yaml` (currently stock, nothing enabled).
- [x] Revisit `dependency_overrides` pins *(removed 2026-11-12: unpinned 13.3.0 / 10.2.2 build cleanly for Android debug + iOS debug under AGP 9.0.1)* (`package_info_plus`, `device_info_plus`)
  after the AGP-9 fix lands upstream — overrides silently hold them back forever.
- [x] Rename `test/live_csv_test.dart` *(now `test/csv_line_endings_test.dart`, 2026-11-12)* (it's an in-memory regression test, not live;
  name invites quarantining).
- [x] Drop `NSLocationAlwaysAndWhenInUseUsageDescription` from `ios/Runner/Info.plist`
  (app is when-in-use only; can invite App Review questions).
- [ ] Smaller (done 2026-11-12: tab clamp, sweep-timer emit, NaN guard, `init()`
  memoization — the rest remain): clamp `LastTabStore.loadInitial` to tab count (crash loop on corrupt
  index); cart staleness compares server timestamps to device clock
  (`cart_positions_repository.dart:41-42,65-68` — drifted phones show no carts or
  ghosts); sweep timer emits every 30s even when nothing changed (`:129`); NaN can
  escape `MapGeoReference.project` bounds check on degenerate control points
  (`map_georeference.dart:42-45,66-68`); `NotificationService.init()` not
  concurrency-safe (memoize the future); delete template TODO comment in
  `android/app/build.gradle.kts:31`; dead "Path B" data in
  `venue_map_data.dart:78-109` (ask before deleting).
