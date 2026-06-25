# Play On Con

A companion app (Beta) for **Play On Con** — a tabletop and gaming convention held at
the Alabama 4-H Center in Columbiana, AL.

Built with Flutter for **iOS and Android**, Play On Con is **offline-first**: the full
schedule and venue map work with no connectivity, so attendees can plan their weekend
even in a cabin with one bar of signal. There is no backend — a published Google Sheet is
the single source of truth.

![Platforms](https://img.shields.io/badge/platforms-iOS%20%7C%20Android-2D5E3E)
![Flutter](https://img.shields.io/badge/Flutter-3-blue?logo=flutter)
![Dart](https://img.shields.io/badge/Dart-3-0175C2?logo=dart)
![Offline-first](https://img.shields.io/badge/offline-first-success)

---

## Features

- **Full schedule, offline.** Browse every session across all four days. "All Sessions"
  opens scrolled to the current time slot so you always land on "what's on now."
- **My Schedule + reminders.** Save sessions you care about and get on-device reminders
  (at start, or a custom number of minutes before) — local notifications, no push required.
- **Phone-native venue map.** A clean, large-target map with category-colored pins that
  carry de-conflicting labels (Apple-Maps style), an Overview ⇄ Detail zoom, a tap-to-open
  info sheet (walk time + what's-on-now), and an opt-in **"you are here"** dot driven by GPS.
- **Show on map.** Jump straight from any session to its venue pin.
- **Attribute tags.** Sessions surface badges parsed from the sheet — `21+`, `Sensory
  Friendly`, `Sign up at Open Gaming`, and more — with unknown tags passing through
  gracefully.
- **Discord + sync status.** A quick link to the community and a clear "last synced" /
  manual-refresh control.

## Tech stack

| Area | Choice |
|---|---|
| Framework | Flutter + Dart 3 |
| State | [Riverpod](https://riverpod.dev) |
| Data ingest | `http` + `csv` (Google Sheet published as CSV) |
| Offline cache | `path_provider` (on-device JSON cache + bundled fallback) |
| Connectivity | `connectivity_plus` (auto re-sync when back online) |
| Reminders | `flutter_local_notifications` + `timezone` + `flutter_timezone` |
| Location | `geolocator` (you-are-here dot) |
| Misc | `url_launcher`, `intl`, `scrollable_positioned_list` |
| Backend | **None** — a Google Sheet CSV is the only data source |

## How it works

```
Google Sheet (grid CSV, one tab per day-range)
        │  http + csv
        ▼
CsvScheduleParser ──► Events (with attributes + resolved venue)
        │                     │
        │ cache to disk       │ column ↔ hotspot matching
        ▼                     ▼
schedule_cache.json     assets/data/locations.json (venue pins)
        │
        ▼
ScheduleRepository (Riverpod StateNotifier) ──► Schedule / Map / Info UI
```

The schedule is a **2-D grid** (venues across the top, time down the side), not a row-per-
event list. The parser walks the grid, anchors day-of-week rows to real calendar dates,
handles late-night roll-over (a 1 AM after a PM time is "tomorrow"), strips `[TAG]` codes
from cell text, and matches each venue column to a map pin. On first launch with no network
it serves a bundled fallback schedule; thereafter it caches the last good sync and refreshes
automatically when connectivity returns.

See [`CLAUDE.md`](CLAUDE.md) for the deep-dive on the sheet format, tag registry, and the
venue map's georeferencing / event-to-hotspot matching.

## Project layout

```
lib/
  main.dart, app.dart            root + bottom-nav scaffold
  app_navigation.dart            tab + "show on map" deep-link providers
  config/app_config.dart         reads --dart-define vars (never hardcoded)
  models/
    event.dart                   Event data class + JSON codec
    event_attribute.dart         [TAG] → label/icon registry
    venue_location.dart          map hotspot (normalized rect + aliases)
  services/
    csv_parser.dart              grid-CSV walker
    schedule_repository.dart     fetch / cache / expose events
    saved_events_store.dart      "My Schedule" + reminder persistence
    notification_service.dart    local reminder scheduling
    locations_store.dart         hotspot read/write + provider
    location_service.dart        device position stream
    map_georeference.dart        GPS → map-image coords (affine fit)
    network_monitor.dart         connectivity stream
  features/
    schedule/                    All Sessions / My Schedule, detail, reminders
    map/                         venue map (pins, info sheet, hotspot editor)
    info/                        Discord, last-sync, refresh
  theme/poc_theme.dart           color palette + Material 3 theme
assets/
  images/venue-map.png           annotated venue diagram
  data/locations.json            bundled hotspot rects (normalized 0–1)
  data/fallback-schedule.json    first-launch offline schedule
test/                            CSV parser + grid/tag fixtures
```

## Getting started

**Prerequisites:** Flutter (Dart 3 SDK), and Xcode (iOS) and/or Android Studio for device
builds. Verify with `flutter doctor`.

```bash
git clone https://github.com/fullerc/playoncon.git
cd playoncon
flutter pub get
```

### Run

All environment-specific values are passed via `--dart-define` (nothing is hardcoded), so a
debug run needs them on the command line:

```bash
flutter run -d <device-id> \
  --dart-define=POC_SCHEDULE_CSV_URL='<csv-url>[,<csv-url>...]' \
  --dart-define=POC_DISCORD_INVITE_URL='<discord-invite-url>' \
  --dart-define=POC_EVENT_THURSDAY=YYYY-MM-DD
```

The canonical production values live in [`scripts/build-testflight.sh`](scripts/build-testflight.sh)
and [`scripts/build-play.sh`](scripts/build-play.sh) — copy them from there.

### Configuration

| Define | Purpose |
|---|---|
| `POC_SCHEDULE_CSV_URL` | Comma-separated list of published CSV URLs (one per sheet tab) |
| `POC_DISCORD_INVITE_URL` | Discord invite link |
| `POC_EVENT_THURSDAY` | `yyyy-MM-dd`; anchors the grid CSV to real calendar dates |
| `POC_ONESIGNAL_APP_ID` | OneSignal app id (reserved for future push) |

> `--dart-define` values are baked at build time — changing one requires a fresh
> `flutter run`, not a hot reload.

## Testing

```bash
flutter test                       # all tests
flutter test test/csv_parser_test.dart   # parser only
flutter analyze --no-pub           # static analysis
```

## Building & releasing

Release builds are **not** launched with `flutter run`, so the `--dart-define` values must
be compiled in. The two scripts handle that (edit the sheet ids / event date at the top of
each when a new year's schedule goes live, and bump the build number in `pubspec.yaml`
before every upload):

```bash
./scripts/build-testflight.sh    # → build/ios/ipa/playoncon.ipa  (TestFlight)
./scripts/build-play.sh          # → build/app/outputs/bundle/release/app-release.aab  (Play)
```

- **TestFlight:** upload the `.ipa` via Transporter, Xcode Organizer, or
  `xcrun altool --upload-app … --apiKey <id> --apiIssuer <id>`.
- **Google Play:** push the `.aab` to a testing track via the Play Console or
  `fastlane supply --aab … --json_key … --track internal --package_name com.fuller.playoncon`.

Distribution channels: **TestFlight** (iOS) and **Google Play** (Android).

## The venue map

The map reuses the hand-annotated venue diagram as its base inside an `InteractiveViewer`,
then layers a constant-size pin overlay on top:

- **Category pins** (Stages, Gaming, Parties, Outdoors, Stay & Eat) re-project from the live
  pan/zoom transform so they stay readable at any zoom, with **greedy label de-confliction**
  so labels never stack — more reveal as you zoom in, and the selected pin's label always wins.
- **Overview ⇄ Detail** presets toggle between a whole-camp glance (pins collapse to dots)
  and a readable, centered view.
- **You-are-here** is opt-in (no launch-time location prompt). Position comes from GPS mapped
  to image coordinates via a least-squares affine fit in `map_georeference.dart`; the dot
  hides when you're not at the venue.
- A **debug-only hotspot editor** (pencil icon, `kDebugMode` only) lets you drag/resize pins
  and export calibrated JSON — it never ships in release builds.

## License

Private companion app for the Play On Con event. All rights reserved.
