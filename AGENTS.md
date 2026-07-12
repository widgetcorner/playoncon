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
    csv_parser.dart                   grid walker for CSV (parse) and Sheets API grid (parseGrid, merge-aware)
    sheets_api_client.dart            Sheets API v4 client — pulls rows + merge ranges
    schedule_repository.dart          fetch/cache/expose events (StateNotifier)
    locations_store.dart              hotspot read/write + venueLocationsProvider
    saved_events_store.dart           "My Schedule": event ID → Reminder + last custom (persisted)
    notification_service.dart         local reminder scheduling (flutter_local_notifications)
    location_service.dart             device position stream (geolocator) for the map dot
    map_georeference.dart             GPS → normalized image coords (affine fit to control points)
    network_monitor.dart              connectivity stream
  app_navigation.dart                 selectedTab + mapFocus providers ("Show on map")
  theme/poc_theme.dart                light + dark ThemeData ("campground at night") and the
                                      PocPalette ThemeExtension for app-specific color roles
                                      (pills, map chrome, brand accents) — widgets read
                                      PocPalette.of(context), never PocColors statics
  features/
    schedule/  schedule_page (All Sessions / My Schedule tabs), event_detail_page,
               attribute_pill, save_event_action (save + reminder dialog)
    map/       venue_map_page (debug-only hotspot editor; "Show on map" focus+highlight)
    info/      info_page (Discord, last-sync, refresh)
assets/
  images/venue-map.png                annotated venue diagram
  images/venue-map-dark.png           dark variant, generated — do not hand-edit; rerun
                                      scripts/make-dark-map.py after changing the light map
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
| `POC_SHEETS_API_KEY` | Google Sheets API v4 key. When set alongside `POC_SHEET_ID` + `POC_SHEET_GIDS`, the app fetches via the API (merged cells preserved) instead of the CSV export. Sheet must be a **native Google Sheet**, not .xlsx |
| `POC_SHEET_ID` | Spreadsheet ID (from `/d/<id>/` in the sheet URL) — used with the Sheets API path |
| `POC_SHEET_GIDS` | **Comma-separated** list of tab gids (numeric) to pull — Sheets API path |
| `POC_SCHEDULE_CSV_URL` | **Comma-separated** list of published CSV URLs (one per sheet tab). Legacy fallback when the API defines are missing — durations get a 1-hour default + stretch-to-next heuristic |
| `POC_SCHEDULE_VIEW_URL` | Browser-viewable Google Sheet URL — "Printable schedule" tile on the Info page |
| `POC_DISCORD_INVITE_URL` | Discord invite |
| `POC_PROGRAM_URL` | Public link to the full program (Google Doc / hosted PDF) — "Program" tile on the Info page |
| `POC_EVENT_THURSDAY` | yyyy-MM-dd; anchors the grid CSV to real calendar dates |
| `POC_ONESIGNAL_APP_ID` | OneSignal app id (M2) |
| `POC_SUPABASE_URL` | Supabase project URL — powers the live golf-cart map layer |
| `POC_SUPABASE_PUBLISHABLE_KEY` | Supabase default publishable API key (`sb_publishable_...`, not the legacy anon JWT) |

Supabase is optional: when either var is empty the cart layer is disabled and
the app still works fully offline. Both vars must be set for the live cart
subscription to come up.

## Run

```bash
flutter run -d <device-id> \
  --dart-define=POC_SHEETS_API_KEY='<sheets-api-key>' \
  --dart-define=POC_SHEET_ID='<spreadsheet-id>' \
  --dart-define=POC_SHEET_GIDS='<gid>[,<gid>...]' \
  --dart-define=POC_SCHEDULE_CSV_URL='<csv-url>[,<csv-url>...]' \
  --dart-define=POC_SCHEDULE_VIEW_URL='<sheet-view-url>' \
  --dart-define=POC_DISCORD_INVITE_URL='<discord-url>' \
  --dart-define=POC_PROGRAM_URL='<program-doc-url>' \
  --dart-define=POC_EVENT_THURSDAY=YYYY-MM-DD \
  --dart-define=POC_SUPABASE_URL='<supabase-url>' \
  --dart-define=POC_SUPABASE_PUBLISHABLE_KEY='<sb_publishable_...>'
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
- Duration comes from the sheet's **vertical merge span** on the API path: a 1-cell
  entry is a 1-hour event, a 2-row merge is 2 hours, etc. Google Sheets' CSV export
  drops merges entirely, so the legacy CSV path defaults every event to 1 hour and
  stretches it to the next non-empty slot in the same column — which over-inflates
  events with a following gap (Malevolent Karaoke, Welcome Wagon in 2026). The
  API path removes that guesswork; keep the sheet a **native Google Sheet** to
  keep it available.
- Horizontal header merges are how `Outdoors` covers multiple physical columns
  (e.g. Archery lives in the second column under a spanning "Outdoors" header).
  The API path inherits the header from the merge anchor; the CSV path can't and
  drops those events.
- The Google Sheets CSV export uses **CRLF row separators with bare LF inside quoted
  multi-line cells** — the parser uses the default `eol` to distinguish the two.
- Sheet tabs are split into separate gids; pass each as a CSV URL in the comma-separated list.

### Event attribute tags

Indicators (21+, sensory friendly, etc.) live **inline in the cell text** — never as
inserted images. Sheets' CSV export drops images entirely, so anything added via
Insert → Image won't survive the round-trip; the schedule editors type the marker
directly into the cell, e.g. `Werewolf 🔥 🎧`. The parser strips markers from the title
and stores them on `event.attributes` (case-insensitive, position-independent, multiple
per cell).

Two formats are accepted in parallel — the 2026 sheet uses emojis; bracket codes are
the older form, still parsed so cached schedules from earlier in the year keep working.
The full mapping lives in `_emojiAttributes` / `_attrRe` in `lib/services/csv_parser.dart`.

| Emoji (2026+) | Bracket (legacy) | Meaning |
|---|---|---|
| 🚫 | `[18+]` | Ages 18+ Only |
| 🔥 (was 🍷) | `[21+]` | Ages 21+ Only |
| ⚠️ | `[PG13]` | Not for Children |
| 🎓 | `[AT]` | Apprentice Track |
| 🎧 | `[SF]` | Sensory Friendly |
| — | `[A]` | Auditioned / Casted |
| — | `[OG]` | Sign up at Open Gaming |

The 🚫/🔥 pair replaced 🔞/🍷 mid-2026; both are still accepted. Unknown markers
(e.g. a new `[VIP]` or unfamiliar emoji) pass through as generic pills with no app
rebuild needed — the registry in `lib/models/event_attribute.dart` is a fallback,
not a gate. To teach the parser a new emoji, add it to `_emojiAttributes`; to label
it nicely, add an entry in the event-attribute registry.

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

## Live golf-cart layer

Companion to the **PlayOnConDrivers** app (sibling repo at
`~/Developer/PlayOnConDrivers/`). Drivers broadcast cart GPS to Supabase every
~10s via the `post_position` RPC; this app subscribes and renders yellow
`Icons.electric_rickshaw` markers on the venue map.

- `lib/models/cart_position.dart` — row decoder for `cart_positions` (tolerates
  Realtime payloads that omit the joined `display_name`).
- `lib/services/cart_positions_repository.dart` — `cartPositionsProvider`
  (`StreamProvider<Map<String, CartPosition>>`). Bootstraps with a one-shot
  `carts` lookup (for names) + a recent positions fetch, then subscribes to
  `client.channel('public:cart_positions').onPostgresChanges(... insert ...)`
  and sweeps stale entries every 30s. Stale window: 2 min — long enough to
  forgive brief tunnel/garage gaps, short enough that ghosts clear quickly
  after a driver signs off.
- `lib/features/map/venue_map_page.dart` — watches the provider (short-circuited
  to empty during the debug hotspot editor) and projects each cart's lat/lng
  through `MapGeoReference.instance.project(...)`, same affine as the "you are
  here" dot. Carts outside the projected map bounds (or unprojectable) are
  hidden. Marker layer sits above unselected venue pins, below the selected
  pin so the user's tapped venue stays on top.

When `POC_SUPABASE_URL` / `POC_SUPABASE_PUBLISHABLE_KEY` are unset, the provider
returns a permanently-empty stream — no cart markers, no Supabase init, no
network traffic. The rest of the app is unaffected.

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

- Dark mode follows the OS setting (`themeMode: ThemeMode.system`; no in-app toggle).
  Both themes derive from the same badge palette — dark's primary is the moss green the
  light scheme uses as `inversePrimary`. Category pin colors carry a `darkColor` variant
  in `venue_map_data.dart` (one step lighter for the dark map ground). New widget colors
  go through `PocPalette` / `Theme.of(context).colorScheme`, not `PocColors` statics —
  a hardcoded light-palette color will look broken for every dark-mode user.

- A column resolves to exactly **one** pin, but several columns may share a pin via `aliases`
  (the Gaming building does this). `Outdoors` is the per-event exception, spread across real
  pins via the title-hint fallback above. Renaming a `displayName`/`alias` away from what the
  sheet says (header or hint) orphans those events from the map.
- The cache file (`<appDocs>/schedule_cache.json`) and the fallback bundled JSON store
  events with the `attributes` field; old caches without it default to `[]`.
- "My Schedule" lives in `<appDocs>/saved_events.json` (`savedEventsProvider`) as a map of
  event ID → `Reminder`, where `Reminder.leadMinutes` is `null` (none) / `0` (at start) /
  `>0` (that many minutes before). IDs are the parser's `title|start|location` hash, so a save
  survives re-sync unless the sheet cell text/time/venue changes — then it silently drops
  (acceptable for a con app). Decode tolerates the legacy enum-name strings.
- Saving prompts a reminder dialog (`save_event_action.dart`): once a custom time has been
  picked it leads the list as a one-tap option, followed by **Custom…** (1–120 min wheel),
  **At start time**, **No reminder**. That last custom value persists in
  `<appDocs>/last_custom_reminder.json` (`lastCustomReminderProvider`). A non-none choice
  requests notification permission then schedules via `NotificationService`.
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
