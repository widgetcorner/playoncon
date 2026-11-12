# Apple draft screenshots

`apple_store_screenshots.py` uses Apple's current App Asset Library API. It uploads
screenshots and places them on exactly one existing iOS App Store version and
localization. It never submits an app or asset for review, publishes a version,
changes its linked build, or deletes underlying library images.

For an explicitly requested App Store screenshot update, first capture the real
production app on native Apple simulators. The capture-only entry point freezes
the schedule, clock, saves, last sync, connectivity, location, and carts. It keeps
system fonts, emoji, status bars, safe areas, and the real Apple/Duo layout event
stream; it hides debug map controls. It is separate from the release app target.

```bash
# Build once; keep Flutter builds sequential because they share a cache.
./scripts/capture-apple-store-assets.sh build

# Install the same capture app on each already-booted simulator.
./scripts/capture-apple-store-assets.sh install <simulator-UDID>
./scripts/capture-apple-store-assets.sh capture <iPhone-UDID> <output>/iphone light
./scripts/capture-apple-store-assets.sh capture <iPad-UDID> <output>/ipad light

# Set the native Duo pose in Device Hub before each capture.
# Closed portrait: outer display 1 (primary), 1398×2034.
POC_CAPTURE_DISPLAY=1 ./scripts/capture-apple-store-assets.sh capture \
  <Duo-UDID> <output>/duo-outer light
# Open landscape: inner display 3 (primary-1), 2853×2007.
POC_CAPTURE_DISPLAY=3 ./scripts/capture-apple-store-assets.sh capture \
  <Duo-UDID> <output>/duo-inner light
```

The wrapper does not change the Duo pose. Each invocation captures five screens
in order: `01-all-sessions`, `02-my-schedule`, `03-event-detail`, `04-venue-map`,
and `05-info`. Use `dark` in place of `light` for an additional OS appearance.
The current portrait iPhone 18 Pro is 1206×2622 and iPad Pro 13 is 2064×2752.
Review every image at its native size before preparing a placement manifest.

Before each launch, the wrapper writes `Documents/poc_capture_request.json` in
the simulator app's data container with a screen and unique nonce. The capture
target reads that file before starting the app, then echoes the nonce in a fresh
app-ready marker proving route, appearance, fixture count, and actual viewport
dimensions. No launch-environment propagation is required. The wrapper selects
`POC_CAPTURE_DISPLAY` when
provided and ignores simulator display masks. The local PNG encoder preserves
every RGB sample and color metadata, strips only an opaque alpha channel, and
rejects mismatched dimensions, transparency, or blank/inactive displays. Delivered
PNGs are non-interlaced 24-bit RGB; raw screenshots and request/ready records remain
in a private temporary directory. Each delivered PNG has a matching ready JSON
file. If startup fails, inspect the simulator's unified log for `POC_CAPTURE` or
the `Runner` process.

The manifest pins the App Store app ID, bundle ID, full version/build, localization,
and ordered files per placement group. Paths are relative to the manifest and must
remain inside its directory. Use opaque, non-interlaced, 24-bit RGB PNG files.

```json
{
  "schema_version": 1,
  "app_id": "<exact numeric App Store app ID>",
  "bundle_id": "com.fuller.playoncon",
  "version": "2026.10.6+28",
  "locale": "en-US",
  "sets": [
    {
      "placement_group": "IPHONE_DYNAMIC_ISLAND_MEDIUM_PROFILE",
      "screenshots": [
        {"path": "iphone/01-all-sessions.png", "width": 1206, "height": 2622}
      ]
    },
    {
      "placement_group": "IPAD_13_PROFILE",
      "screenshots": [
        {"path": "ipad/01-all-sessions.png", "width": 2064, "height": 2752}
      ]
    },
    {
      "placement_group": "IPHONE_DUO_PROFILE",
      "screenshots": [
        {"path": "duo-outer/01-all-sessions.png", "width": 1398, "height": 2034},
        {"path": "duo-inner/01-all-sessions.png", "width": 2853, "height": 2007}
      ]
    }
  ]
}
```

The group names above are examples confirmed on October 6, 2026. Every remote
operation fetches Apple's current catalog and checks groups, dimensions, image
specifications, categories, and placement count limits. Duo currently permits ten
screenshots total across both displays in one group. No deprecated screenshot
display enum is needed.

```bash
# Entirely local: verify PNGs and list their computed source hashes.
python3 scripts/apple_store_screenshots.py plan --manifest <manifest.json>

# GET requests only: verify the target draft/build and compare its placements.
python3 scripts/apple_store_screenshots.py check --manifest <manifest.json> \
  --receipt build/releases/2026.10.6+28/apple-screenshots-check.json

# Upload only after the images have been reviewed and this operation authorized.
python3 scripts/apple_store_screenshots.py upload --manifest <manifest.json> \
  --receipt build/releases/2026.10.6+28/apple-screenshots-upload.json
```

The helper loads Apple credentials through the existing ignored release
configuration. It requires the exact draft to be `PREPARE_FOR_SUBMISSION`, linked
to the exact uploaded `VALID` build. Nonempty targeted placement groups must match
the expected source identities and order, or be a matching ordered prefix of the
manifest. A partial prefix is preserved and only its missing suffix is placed,
followed by an explicit ordering request for the complete group. A nonmatching
group is refused before uploading;
`upload --replace` requires explicit authorization to replace those groups.
Other groups, localizations, app versions, and reusable images are preserved.

Image transfers use Apple's returned HTTPS method, headers and byte ranges,
without an App Store JWT. Every image must finish processing and match the
intended catalog specification before placement changes begin. The helper posts
an explicit ordering request, then reads back placement IDs, image IDs, state,
source identity, file size and dimensions for every targeted group.

Apple's documentation shows placement state `PARENT_PREPARE_FOR_SUBMISSION`; the
live API returned `ACTIVE` for this pending draft on October 6, 2026. The helper
accepts both, while independently requiring the exact parent version to remain
`PREPARE_FOR_SUBMISSION` and linked to the exact manifest build before writes.
`ACTIVE` alone is never treated as evidence that a published version is editable.

Apple's new API does not expose an original-source checksum or original-byte
download URL. The helper stores a local SHA256 in the image's `referenceName` and
receipt as an immutable-source identity marker; this is not an independently
computed server checksum. It never mistakes a processed thumbnail's hash for the
source hash. Existing matching assets are reused for safe retries.

Apple screenshot writes are not atomic. If a request fails, the receipt records
known asset/placement IDs and an incomplete state. Run `check` and inspect the
draft/library before retrying. A missing response is never grounds for blindly
repeating a reservation, commit, placement, or ordering request. Failed or
incomplete assets may remain in the library; this helper does not delete them.

A retry can recover an `AWAITING_UPLOAD` reservation: it first reads that exact
asset, verifies its filename, size, category and source marker, then transfers
the bound source using fresh upload operations and commits once. It only polls
an asset already in `UPLOAD_COMPLETE`. A `FAILED` asset causes an explicit error
naming the asset ID; inspect and manually remove that failed asset before
retrying. The helper never creates a duplicate to bypass an ambiguous or failed
reservation.

Sources: [Asset Library](https://developer.apple.com/documentation/appstoreconnectapi/app-asset-library),
[image uploads](https://developer.apple.com/documentation/appstoreconnectapi/uploading-and-managing-image-assets),
[placement and ordering](https://developer.apple.com/documentation/appstoreconnectapi/placing-assets-on-your-app-store-surfaces),
[runtime specifications](https://developer.apple.com/documentation/appstoreconnectapi/discovering-asset-specifications),
[migration](https://developer.apple.com/documentation/appstoreconnectapi/migrating-to-the-app-asset-library).
