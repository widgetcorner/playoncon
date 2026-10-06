# Google Play phone screenshots

These candidate listing assets render the real Android app interface. The
ordered `manifest.json` is the source of truth for the en-US phone screenshot
set. They have not been uploaded as part of adding this automation.

| Position | File | In-app route |
| --- | --- | --- |
| 1 | `01-all-sessions.png` | Schedule → All Sessions |
| 2 | `02-my-schedule.png` | Schedule → My Schedule |
| 3 | `03-event-detail.png` | My Schedule → Make a Holiday Card |
| 4 | `04-venue-map.png` | Event detail → Show on map; Lodge selected |
| 5 | `05-info.png` | Info; logo, countdown, and venue |

Every screenshot is an opaque 24-bit RGB PNG at 1080 × 1920. The renderer uses
a 360 × 640 logical phone viewport at 3× output scale and Android styling,
Roboto, Material icons, Android emoji, and production shadows. PNGs are ready
for Google Play without a JPEG conversion. The matching `dark/` files are
previews and are not included in the default upload manifest.

## Regenerate and review

From the repository root:

```sh
./scripts/capture-store-assets.sh
python3 scripts/store_screenshots.py plan
```

The capture script reads no credentials and makes no network calls. It renders
production widgets, follows real navigation, checks for widget errors, verifies
dimensions and opaque pixels, and writes the ten PNGs. It loads Roboto from the
installed Flutter SDK; the Android emoji font is included in `tool/fonts/`.
Inspect the screenshots after every UI change before uploading. Two successive
captures on the same Flutter version should be byte-for-byte identical.

The fixture is deliberately independent of `assets/data/fallback-schedule.json`:

- `test/fixtures/screenshot-schedule.json` freezes the real 103-session 2026
  schedule from the merge-aware Sheets API, with matched program descriptions.
- `test/fixtures/screenshot-scenario.json` fixes venue time at July 2, 2026,
  3:45 PM Central, selects the detail event, and seeds four saved sessions with
  15-minute reminders.
- `test/fixtures/screenshot-config.json` fixes the public Info links and
  convention start date. App-version text is omitted to prevent every build
  number from changing a screenshot.

Network status, initial navigation, map focus, device location, carts, and
calibration state are controlled by the harness. Editor and calibration buttons
are hidden to show the release interface. The app's existing BETA badges are
retained. Production behavior uses the normal device clock and debug controls.

Do not refresh these fixtures during a ship. Update them intentionally when the
listing needs a new season or different example sessions, then regenerate and
review the entire set. Schedule refreshes alone must not change store images.

## Upload changed screenshots

`scripts/store_screenshots.py` reads the manifest in its listed order and changes
only the en-US `phoneScreenshots` set. The existing feature graphic, app icon,
listing text, app binary, other locales, and other screenshot types remain as
they are. `check` compares live image hashes and order; `validate` checks a
staged edit without committing; `upload` validates, commits, and reads back the
SHA-256 hashes and order. Identical screenshots are skipped.

```sh
python3 scripts/store_screenshots.py check
python3 scripts/store_screenshots.py validate
python3 scripts/store_screenshots.py upload
```

The Google Play service account needs **Manage store presence**, in addition
to any permission used for release uploads. The ship skill handles screenshot
upload failures separately from binary delivery so a listing issue does not
cause another build or version bump.

These are Android screenshots, suitable for Google Play. This harness does not
produce App Store screenshots or upload to App Store Connect.

## Android emoji font

`tool/fonts/Noto-COLRv1.ttf` is test-only and does not enter the app bundle. It is
from [Google's Noto Emoji project](https://github.com/googlefonts/noto-emoji),
commit `1ffdd21391dd1f25c081fa93a9dea0c7c029442b`, at
`2D/fonts/Noto-COLRv1.ttf`. SHA-256:
`b8e25ea68db82f9e4d0aee921f4420be2be39887bd5c893a2ad98710531f9d0c`.
The accompanying `Noto-Emoji-LICENSE.txt` contains the SIL Open Font License.
The vector color format works in the macOS Flutter test runner; the SDK's
Android bitmap emoji font produced missing glyphs on this host. Override
`POC_CAPTURE_EMOJI_FONT` only when intentionally testing another Android emoji
font, and visually verify the result.
