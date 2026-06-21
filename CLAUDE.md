# Play On Con — Flutter app

Cross-platform (iOS + Android) Flutter companion app for **Play On Con**, a tabletop/gaming
convention at the Alabama 4-H Center in Columbiana, AL. Offline-first: schedule and venue
map must work without connectivity. Distribution: TestFlight + Google Play.

Architecture/decision doc: `~/.claude/plans/enumerated-launching-puddle.md` (read this for
the why behind major decisions).

## Stack

- Flutter + Dart 3, Riverpod for state
- `http` + `csv` for sheet ingest, `path_provider` for cache, `connectivity_plus` for
  online/offline, `url_launcher` for Discord, `intl` for dates
- `onesignal_flutter` for push (M2)
- `flutter_local_notifications` + `timezone` + `flutter_timezone` for on-device event reminders
- `scrollable_positioned_list` so "All Sessions" can open scrolled to the current time
- `geolocator` for the "you are here" dot on the venue map
- No backend — a Google Sheet published as CSV is the only data source

## File layout (key paths)

```
lib/
  main.dart, app.dart                 root + bottom-nav scaffold
  config/app_config.dart              reads --dart-define vars; never hardcode
  models/
    event.dart                        Event data class + JSON codec
    event_attribute.dart              [TAG] code → label/icon registry
    venue_location.dart               Hotspot data class + copyWith + aliases
  services/
    csv_parser.dart                   grid CSV walker (see "Sheet format")
    schedule_repository.dart          fetch/cache/expose events (StateNotifier)
    locations_store.dart              hotspot read/write + venueLocationsProvider
    saved_events_store.dart           "My Schedule": event ID → ReminderOption (persisted)
    notification_service.dart         local reminder scheduling (flutter_local_notifications)
    location_service.dart             device position stream (geolocator) for the map dot
    map_georeference.dart             GPS → normalized image coords (affine fit to control points)
    network_monitor.dart              connectivity stream
  app_navigation.dart                 selectedTab + mapFocus providers ("Show on map")
  features/
    schedule/  schedule_page (All Sessions / My Schedule tabs), event_detail_page,
               attribute_pill, save_event_action (save + reminder dialog)
    map/       venue_map_page (debug-only hotspot editor; "Show on map" focus+highlight)
    info/      info_page (Discord, last-sync, refresh)
assets/
  images/venue-map.png                annotated venue diagram
  data/locations.json                 bundled hotspot rects (normalized 0–1)
  data/fallback-schedule.json         used on first launch with no network
test/
  csv_parser_test.dart + fixtures/    grid parse + tag extraction tests
```

## Configuration (no hardcoding)

All environment-specific values pass through `--dart-define`. Read them in
`lib/config/app_config.dart`:

| Define | Purpose |
|---|---|
| `POC_SCHEDULE_CSV_URL` | **Comma-separated** list of published CSV URLs (one per sheet tab) |
| `POC_DISCORD_INVITE_URL` | Discord invite |
| `POC_EVENT_THURSDAY` | yyyy-MM-dd; anchors the grid CSV to real calendar dates |
| `POC_ONESIGNAL_APP_ID` | OneSignal app id (M2) |

## Run

```bash
flutter run -d <device-id> \
  --dart-define=POC_SCHEDULE_CSV_URL='<csv-url>[,<csv-url>...]' \
  --dart-define=POC_DISCORD_INVITE_URL='<discord-url>' \
  --dart-define=POC_EVENT_THURSDAY=YYYY-MM-DD
```

Wireless iOS debug bridges drop often ("Lost connection to device"); the installed app
keeps running on the phone, only hot-reload disconnects. USB cable fixes it.

## Test

```bash
flutter test                              # all
flutter test test/csv_parser_test.dart    # parser only
flutter analyze --no-pub                  # static check
```

## Sheet format

The Play On Con schedule is a **2-D grid CSV**, not a per-event row list:

```
            | Theater | Main Gaming | RPG Rooms | ... | Lower Mayfield |
Thursday    |
4 PM        |         |             |           |     |                |
5 PM        | Welcome |             |           |     |                |
...
Friday      |
10 AM       | Stage   |             |           |     |                |
```

- The first row of all-text in column 0 named after a day (`Thursday`/`Friday`/`Saturday`/`Sunday`)
  resets the current date.
- Time rows in column 0 (`4 PM`, `Noon`, `Midnight`, `1 AM`, ...) set the start time. The
  parser handles late-night roll: an AM time after a PM time on the same day flips to the
  next calendar day.
- Each non-empty cell at a venue column becomes one `Event`.
- The Google Sheets CSV export uses **CRLF row separators with bare LF inside quoted
  multi-line cells** — the parser uses the default `eol` to distinguish the two.
- Sheet tabs are split into separate gids; pass each as a CSV URL in the comma-separated list.

### Event attribute tags

Cell text can carry `[CODE]` tokens — the parser strips them from the title and stores them
on `event.attributes`. Codes are case-insensitive, position-independent, multiple per cell.

| Code | Meaning |
|---|---|
| `[21+]` | Ages 21+ Only |
| `[PG13]` | Not for Children |
| `[AT]` | Apprentice Track |
| `[A]` | Auditioned / Casted |
| `[SF]` | Sensory Friendly |
| `[OG]` | Sign up at Open Gaming |

Unknown codes (e.g. `[VIP]`) pass through as generic pills with no app rebuild needed —
the registry in `lib/models/event_attribute.dart` is a fallback, not a gate.

## "You are here" dot (venue map)

The blue dot is positioned by an affine transform from GPS → normalized image
coords, least-squares–fit to surveyed control points in
`lib/services/map_georeference.dart` (`_points`). The map is a stylized drawing,
so it's approximate (~4% of map size at the fitted points). To recalibrate, edit
`_points` (lat/lng + the landmark's hotspot rect center as x/y) — the fit
recomputes automatically; spread points toward the edges and keep ≥3.

- Location is **opt-in**: the Map tab's locate FAB (`Icons.location_searching` →
  `my_location`) requests permission on first tap, so nothing prompts at launch.
  Returning users who already granted it get the dot automatically.
- `currentPositionProvider` (geolocator stream) only runs once enabled; yields
  `null` when the service/permission is off (dot stays hidden). The dot also hides
  when the projected point falls outside the map bounds (you're not at the venue).
- Permissions are wired: iOS `NSLocationWhenInUseUsageDescription` (Info.plist),
  Android `ACCESS_FINE/COARSE_LOCATION` (manifest). Adding geolocator means a full
  rebuild, not hot reload.

## Hotspot editor

Behind a `kDebugMode` pencil icon on the Map tab AppBar (will not appear in release builds).
Drag body to move, drag corner handle to resize, tap to select, long-press to rename/delete,
+ in the AppBar to add. Save writes `<appDocs>/locations_override.json`; the provider prefers
the override over the bundled asset.

**Workflow when calibration is done:** Copy JSON → paste into `assets/data/locations.json`
→ Reset to clear the override → ship.

## Event-to-hotspot matching

The schedule's venue **columns** (programming areas: `Theater`, `Main Gaming`, `RPG Room 1`,
`Outdoors`, `Lodge`, `Lower Mayfield`, …) are matched to map **hotspots** in two passes
(`CsvScheduleParser._resolveLocation`):

1. **Header match** — the column header is looked up against each hotspot's
   `displayName.toLowerCase()` *and* its `aliases`. So a hotspot answers to the sheet's
   exact column text, and **multiple columns can fan into one pin via aliases**. The
   `gaming` pin (`Main Gaming`) does this: its `aliases` claim the whole Gaming building —
   `RPG Rooms (Gaming Building)`, `Video Gaming (Gaming Building Classroom 2)`, `RPG Room 1`,
   `RPG Room 2`, `Video Gaming` — so tapping it lists every event from all six columns.
   (Events still carry their own `locationDisplayName` = the exact column, so the schedule
   list and event detail show the specific room.)
2. **Title-hint fallback** — only when the header has no pin (currently just `Outdoors`,
   which is a broad category, not a place). The parser reads a parenthesized location hint
   in the event title and matches it via `aliases`/`displayName`, normalized
   (lowercased, punctuation→spaces). E.g. `Beer Croquet (Rec Field)` → `recreation-field`,
   `(Mini-golf)` → `mini-golf`, `(Canopy)` → `picnic-tables`. Outdoors events with no hint
   stay map-unmatched but still appear in the schedule list.

`aliases` lives in `assets/data/locations.json` (optional `"aliases": [...]` per pin), **not
in code** — add a column header or hint variant there, no rebuild of parser logic needed.

Pins with no column (dorms, archery, pool amenities, etc.) are wayfinding-only.

## Constraints / things to know

- A column resolves to exactly **one** pin, but several columns may share a pin via `aliases`
  (the Gaming building does this). `Outdoors` is the per-event exception, spread across real
  pins via the title-hint fallback above. Renaming a `displayName`/`alias` away from what the
  sheet says (header or hint) orphans those events from the map.
- The cache file (`<appDocs>/schedule_cache.json`) and the fallback bundled JSON store
  events with the `attributes` field; old caches without it default to `[]`.
- "My Schedule" lives in `<appDocs>/saved_events.json` (`savedEventsProvider`) as a map of
  event ID → `ReminderOption` (`none`/`atStart`/`fifteenMinutesBefore`). IDs are the parser's
  `title|start|location` hash, so a save survives re-sync unless the sheet cell
  text/time/venue changes — then it silently drops (acceptable for a con app). Saving prompts
  a reminder dialog (`save_event_action.dart`); choosing a non-none option requests
  notification permission then schedules via `NotificationService`.
- "All Sessions" is a `ScrollablePositionedList` that opens at `_nowAnchorIndex` — the first
  session whose end is after `DateTime.now()` (its day header if it's first of the day),
  falling back to the top when the schedule is entirely past/not-yet-started. Applied once on
  first build with data, so a later sync won't yank the user's scroll position.
- Reminders are **local** notifications (device alarm), not OneSignal push. Event times are
  naive wall-clock `DateTime`s, scheduled against the device's local timezone. **Past
  fire-times are skipped** — the 2025 test schedule won't buzz; only future-dated events do.
- Reminders need native config already wired: Android core-library desugaring + manifest
  permissions/receivers (`android/app/build.gradle.kts`, `AndroidManifest.xml`) and the iOS
  `UNUserNotificationCenter` delegate (`AppDelegate.swift`). Changing notification deps means
  a full rebuild (`flutter run`), not hot reload.
- `--dart-define` values bake at build time. Changing one requires a fresh `flutter run`,
  not a hot-reload.

## Owner preferences (Fuller, Salesforce Principal SE)

- Direct, concise responses. No preamble, no "Great question".
- Explain what's changing and why before editing.
- Match existing patterns; prefer small reversible changes.
- Don't delete files/code without asking; never push without being asked.
- Flutter is newer ground for me — Salesforce/Apex is the day job. Frame Flutter
  things in terms of analogues when useful, but don't over-explain basics.
