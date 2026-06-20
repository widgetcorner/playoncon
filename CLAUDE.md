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
- No backend — a Google Sheet published as CSV is the only data source

## File layout (key paths)

```
lib/
  main.dart, app.dart                 root + bottom-nav scaffold
  config/app_config.dart              reads --dart-define vars; never hardcode
  models/
    event.dart                        Event data class + JSON codec
    event_attribute.dart              [TAG] code → label/icon registry
    venue_location.dart               Hotspot data class + copyWith
  services/
    csv_parser.dart                   grid CSV walker (see "Sheet format")
    schedule_repository.dart          fetch/cache/expose events (StateNotifier)
    locations_store.dart              hotspot read/write + venueLocationsProvider
    network_monitor.dart              connectivity stream
  features/
    schedule/  schedule_page, event_detail_page, attribute_pill
    map/       venue_map_page (with debug-only hotspot editor)
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

## Hotspot editor

Behind a `kDebugMode` pencil icon on the Map tab AppBar (will not appear in release builds).
Drag body to move, drag corner handle to resize, tap to select, long-press to rename/delete,
+ in the AppBar to add. Save writes `<appDocs>/locations_override.json`; the provider prefers
the override over the bundled asset.

**Workflow when calibration is done:** Copy JSON → paste into `assets/data/locations.json`
→ Reset to clear the override → ship.

## Constraints / things to know

- Event-to-hotspot matching is by **`displayName.toLowerCase()`** (parser side) against the
  sheet's venue header text. Renaming a hotspot's `displayName` to something the sheet
  doesn't say will orphan its events from the map until renamed back or sheet edited.
- The cache file (`<appDocs>/schedule_cache.json`) and the fallback bundled JSON store
  events with the `attributes` field; old caches without it default to `[]`.
- `--dart-define` values bake at build time. Changing one requires a fresh `flutter run`,
  not a hot-reload.

## Owner preferences (Fuller, Salesforce Principal SE)

- Direct, concise responses. No preamble, no "Great question".
- Explain what's changing and why before editing.
- Match existing patterns; prefer small reversible changes.
- Don't delete files/code without asking; never push without being asked.
- Flutter is newer ground for me — Salesforce/Apex is the day job. Frame Flutter
  things in terms of analogues when useful, but don't over-explain basics.
