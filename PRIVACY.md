# Privacy

Written for attendees and event organizers, not developers. A technical appendix follows at the end.

## In one sentence

The Play On Con app shows the convention schedule and venue map on a phone, saves the sessions an attendee taps to keep, and — only if the attendee turns it on — shows a blue dot on the map where their own phone is. It does not have accounts, does not collect anything about the attendee, and does not send anything off the phone.

## What the app collects from the phone

Nothing is sent off the phone. There is no sign-up, no login, no profile, no analytics, no advertising IDs.

The app stores a few things **on the phone itself** so it works offline and remembers what the attendee saved:

- A cached copy of the schedule (the same public schedule everyone sees)
- The list of sessions the attendee tapped "save" on
- For each saved session, the reminder choice (at start, X minutes before, or no reminder)
- The last "custom reminder" value the attendee picked, so the dialog can offer it next time
- Any hotspot edits made in the debug editor — and the debug editor is not present in the version distributed through the App Store or Google Play

The attendee's name, email, phone number, contacts, photos, microphone, camera, web history, and advertising ID are never read or stored.

## The "you are here" dot

The Map tab has a small location button (a target icon) in the corner. **Nothing happens with GPS until the attendee taps it.** The app does not ask for location at launch.

- Tapping the button asks iOS or Android for location permission **the first time only**. The attendee can say no and the rest of the app still works.
- When permission is granted, the phone's GPS is used to draw a blue dot on the venue map.
- **The GPS reading never leaves the phone.** It is not sent to any server. It is not saved between app launches. The schedule sheet does not see it. The cart map does not see it.
- Tapping the location button again turns the dot off. Closing the app turns it off.
- If the projected position falls outside the venue map (the attendee is not at the 4-H Center), the dot hides automatically.

## The golf-cart map

When the attendee opens the Map tab, the app reads the current position of each shuttle cart from the event's database (hosted on Supabase, a standard cloud service) and shows them as small yellow icons. **This is a one-way read.** The attendee's app does not write anything back to that database. It does not announce who is looking at the map.

What the attendee sees on the cart map is:

- The current location of each cart
- The name the driver-volunteer typed in for that cart

Only positions from the last 2 minutes are visible. When a cart stops broadcasting, its icon disappears from everyone's map within ~2 minutes.

The cart map is a companion to a separate **driver** app used by shuttle volunteers. That driver app — not this attendee app — is what reports cart positions. The driver app has its own privacy notice.

## Reminders for saved sessions

When the attendee taps "save" on a session and picks a reminder time, the app asks the phone for permission to show notifications. The reminder is then **scheduled by the phone itself**, like a built-in alarm. There is no push server, no account, no list of "who saved what" stored anywhere.

If the attendee says no to notifications, sessions still save — they just won't buzz the phone.

## What goes over the network

| Reads | Why |
|---|---|
| The published Google Sheet schedule (a CSV file) | To get the latest session list, times, and venues |
| The cart-positions table on Supabase | To draw moving cart icons on the map |
| Discord, the program document, the printable schedule | Only when the attendee taps a link on the Info tab — and only then |

| Writes | |
|---|---|
| Nothing | The app never sends anything to a server |

The Google Sheet is the same CSV that anyone with the link can view. The Supabase database hides cart positions older than 2 minutes from the attendee app, and only exposes cart IDs and the names the drivers typed in.

## Permissions the app asks for

- **Location, "while using the app" only** — only after the attendee taps the location button on the map. Not requested at launch. Used only to draw the blue dot on the map; the reading is never sent anywhere.
- **Notifications** — only after the attendee saves a session and picks a reminder. Used only for local reminders that fire from the phone.
- **Network** — to download the schedule and read cart positions.
- **Nothing else.** No contacts, no photos, no camera, no microphone, no calendar, no health data, no Bluetooth.

## What is kept, and for how long

On the attendee's phone:

- **Schedule cache:** overwritten on every successful sync. Only the latest copy is kept.
- **Saved sessions and reminders:** kept until the attendee removes them or deletes the app.
- **Last-custom-reminder value:** one number (e.g. "20 minutes"). Overwritten when a new custom value is picked.

Nowhere else: the app does not have an account system, so there is nothing about the attendee stored on any server.

## Honest list of things to know

- **No accounts.** The app cannot tell one attendee's phone from another. There is nothing to "log out of."
- **Names visible on the cart map** are the names driver-volunteers typed in. Those drivers can pick a handle if they don't want their real name shown. This attendee app only displays what the driver app sent.
- **The "you are here" dot is private.** Only the attendee's own phone uses their GPS. Other attendees cannot see where anyone else is.
- **Closing the app stops the GPS dot.** Backgrounding the app stops it. There is no background tracking, and the operating system would not allow any.
- **The schedule is public.** Anyone with the sheet link sees the same schedule. The app just renders it nicely and caches it for offline use.
- **No ads, no analytics, no third-party trackers.** The app does not include Google Analytics, Firebase Analytics, Facebook SDK, AppsFlyer, Crashlytics, or any similar library.

## What this app is not

- **Not a personal tracker.** Location is opt-in, used only to draw a dot on the venue map, and the reading never leaves the phone.
- **Not an account system.** There is no sign-up and nothing tying the app on one phone to the app on another.
- **Not a chat app.** The Info tab links out to Discord; messages happen in Discord, not in this app.
- **Not collecting data outside the list above.**
- **Not sharing data with advertisers, analytics services, or any third party.** The only network destinations are the event's own Google Sheet, the event's own Supabase database (read-only), and whatever link the attendee chooses to tap.

## Bottom line for an attendee

The app shows the schedule and the map, remembers the sessions tapped to save, and (only if asked) draws a dot on the map where the phone is. Closing the app stops everything. There is no account, no profile, and nothing about the attendee leaves the phone.

---

## Technical appendix (for developers and operators)

### On-device behavior

- The schedule is fetched from one or more **published Google Sheet CSV URLs** (`POC_SCHEDULE_CSV_URL`, comma-separated) via plain `http`. Successful responses are cached to `<appDocs>/schedule_cache.json`. On first launch with no network, a bundled `assets/data/fallback-schedule.json` is used.
- **Saved sessions** live in `<appDocs>/saved_events.json` as a map of event-id → `Reminder`. IDs are a hash of `title|start|location`, so a save survives re-sync unless the cell text/time/venue changes.
- **Last custom reminder** lives in `<appDocs>/last_custom_reminder.json`.
- **Hotspot overrides** (from the debug-only editor, `kDebugMode` only) live in `<appDocs>/locations_override.json`. The editor is not reachable in release builds.
- `geolocator` produces position updates only after the user enables the locate FAB on the Map tab. The `currentPositionProvider` (Riverpod) yields `null` until then. Positions are projected to map-image coordinates by `MapGeoReference` (least-squares affine fit) **in-process**; nothing is transmitted or persisted.
- `connectivity_plus` watches online/offline state to trigger schedule re-sync on reconnect.
- `flutter_local_notifications` + `timezone` schedules **device-local** reminders. Past fire-times are skipped. No push server, no OneSignal write (the `POC_ONESIGNAL_APP_ID` define is reserved for future use and currently unused at runtime).

### Permissions declared

- **iOS** (`ios/Runner/Info.plist`): `NSLocationWhenInUseUsageDescription` only — no `Always` or background-location entitlement. Notification permission is requested at first reminder schedule via the standard `UNUserNotificationCenter` flow (`AppDelegate.swift`).
- **Android** (`android/app/src/main/AndroidManifest.xml`): `ACCESS_FINE_LOCATION`, `ACCESS_COARSE_LOCATION`, `INTERNET`, plus the notification permissions required by `flutter_local_notifications`. No `ACCESS_BACKGROUND_LOCATION`, no foreground-service permissions.

### Network destinations

| Destination | Direction | Purpose |
|---|---|---|
| `POC_SCHEDULE_CSV_URL` (Google Sheets `tq?...&tqx=out:csv` exports) | Read | Schedule ingest |
| `POC_SUPABASE_URL` (Supabase REST + Realtime) | Read | Cart positions: one-shot fetch of `carts` + recent `cart_positions`, then a Realtime subscription to inserts on `public:cart_positions` |
| `POC_DISCORD_INVITE_URL`, `POC_PROGRAM_URL`, `POC_SCHEDULE_VIEW_URL` | Read (via `url_launcher`) | Only when the user taps the corresponding Info-tab tile; opens the system browser or the Discord app |

No write to any of the above. The app does not call `post_position` or any other Supabase RPC; that is exclusive to the driver app.

### Supabase access (this app's side)

- Uses the bundled `POC_SUPABASE_PUBLISHABLE_KEY` (the `sb_publishable_...` key). Treat it as public — it is extractable from the `.ipa` / `.apk`.
- RLS on `public.cart_positions` restricts anon reads to `updated_at > now() - interval '2 minutes'`. RLS on `public.carts` allows anon read of cart IDs and `display_name`.
- All writes to those tables go through the driver app's `post_position` Postgres function. This app does not invoke it. (See the **PlayOnConDrivers** repo's privacy section for the write-side threat model and rate-limit details.)
- If `POC_SUPABASE_URL` or `POC_SUPABASE_PUBLISHABLE_KEY` is unset at build time, the Supabase client is not initialized and the cart-positions provider yields a permanently-empty stream — no network traffic to Supabase at all.

### Third-party SDKs in the binary

The app's runtime dependencies are limited to:

- `flutter`, `cupertino_icons` (framework)
- `http`, `csv` (schedule ingest)
- `path_provider`, `shared_preferences` (on-device storage)
- `flutter_riverpod` (state)
- `connectivity_plus` (online/offline)
- `url_launcher` (external links)
- `intl` (date formatting)
- `scrollable_positioned_list` (initial-scroll behavior)
- `flutter_local_notifications`, `timezone`, `flutter_timezone` (local reminders)
- `geolocator` (opt-in GPS for the map dot)
- `supabase_flutter` (read-only cart subscription)

No analytics SDK, no advertising SDK, no crash-reporting SDK, no social-login SDK. `onesignal_flutter` is referenced in design notes as a future milestone but is not currently included in `pubspec.yaml` or shipped in builds.

### Build-time configuration

All environment-specific values pass through `--dart-define` (see `lib/config/app_config.dart` and `scripts/build-testflight.sh` / `scripts/build-play.sh`). Nothing is hardcoded. Supabase config is optional; with either var empty, the cart layer cleanly degrades to off.

### Data deletion

Because the app has no server-side state about attendees, "deleting an attendee's data" is equivalent to either clearing the app's documents directory (Settings → app storage) or uninstalling the app. There is nothing the operator needs to do server-side to remove an attendee — only the driver app's `cart_positions` rows are operator-managed, and those age out of attendee visibility automatically after 2 minutes.
