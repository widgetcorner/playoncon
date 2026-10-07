---
name: ship
description: "Release PlayOnCon to TestFlight and Google Play internal testers, including offline schedule refresh, versioning, verified builds, store notes, changed Play screenshots, and commit/push. Use for $ship, 'ship it', or a request to publish a tester build. Default to both stores; honor an explicit platform-only request. Editing this skill or running on a device does not start a release."
---

# Ship PlayOnCon

Work from the PlayOnCon repository root. App identifier: `com.fuller.playoncon`.
A ship request includes selected tester uploads, store notes, changed Play phone
screenshots, commit, and current-branch push. Honor narrower requests and existing
authorization. Loading, comparing, or editing this skill alone does not authorize
a release. Keep the Codex and Claude copies of this skill in sync.

Read [the release reference](../../../scripts/RELEASE.md) for credential setup,
artifact verification, store commands, metadata retries, and iOS export recovery.

## Establish or resume the release

- Read `git status --short`, staged/unstaged diffs, `pubspec.yaml`, and recent
  commits. Identify intended changes, including already committed app changes
  since the last shipped source. Inspect unfamiliar paths; leave unrelated work
  untouched. Resolve uncertainty affecting the built app before uploading.
- Read both build scripts and `scripts/release-config.sh`. Use their shared
  configuration; bare Flutter builds can omit schedule and other defines.
- Reuse relevant passing checks for unchanged code, or run
  `flutter analyze --no-pub` and applicable tests. Resolve release-relevant
  failures. Run local Python release-tool tests when those helpers changed.
- Stop only this checkout's active `flutter run` session: use its known command
  session with `write_stdin` (`q` or Ctrl-C), or verify PID and working directory
  first. Never kill all Flutter processes; runs/builds share `.dart_tool`.
- Validate upload tools, configuration, and signing before bumping. Use environment
  metadata or gitignored `scripts/.env.local`, not Claude memory. Check existence
  without printing secrets. Android needs `android/key.properties` and its actual
  upload keystore; a debug-signed bundle is not a tester release.
- For interrupted releases, establish version, built source, exact artifact
  paths/hashes, and each store's binary/notes/screenshots results. Check remote
  status if an upload result is uncertain. Resume only unfinished work when
  source and artifacts are unchanged.

Keep a record under gitignored `build/releases/<version>/`: per-platform canonical
notes, built-source revision/diff, artifact paths/hashes, and per-store results. Update
each completed step; record pending metadata separately from accepted binaries.
Never store credentials there. A notes failure or failed push is not a new release.

## 1. Refresh the offline schedule

Run `./scripts/refresh-schedule.sh` before either build. It uses shared sheet/date
configuration, all configured tabs, Sheets API merge data, and the app's parser
and venue aliases. Do not substitute BurlyCon's CSV importer: CSV loses merged
durations and spanning venue headers.

Review tab/event counts, date range, venue matches, and effective description
coverage. The importer preserves the old snapshot on malformed/empty/missing-tab
data and stops on a significant count drop. Inspect the source of a drop before
explicitly allowing it. Include changed `assets/data/fallback-schedule.json`.
A resumed release with accepted binaries retains the snapshot they were built
with; do not refresh or silently change contents during recovery.

## 2. Set the version once

Use `YYYY.M.D+N`: today's local date, unpadded month/day, and a build number that
increases across releases, including date changes. Read the current value first.

```bash
TZ="${POC_RELEASE_TIMEZONE:-America/New_York}" date '+%Y.%-m.%-d'
```

Use `%m` for month; `%n` inserts a newline. For a fresh release use today's
marketing date and increment `+N` once. Never reset it, move marketing backward,
or silently choose a future date. Resolve existing future dates before editing.
For interrupted releases reuse the version when source/artifacts are unchanged.

## 3. Capture and build

For Play, run `./scripts/capture-store-assets.sh`. It captures
actual Android screens with frozen schedule/time/saves/connectivity/location/cart
state and hides debug-only map controls. Its fixture is separate from the live
fallback; update examples only when deliberately changing listing content.

Review images in `design/google-play/manifest.json` order. A byte diff is a cue to
inspect, not proof of meaningful UI change. Fix failed captures and clipped or
unfinished screens before publishing. No changed PNGs normally means no listing
update. For an interrupted screenshot upload or initial setup, check remote hashes
before skipping: a clean checkout alone does not prove the store has these images.

Run selected builds sequentially, iOS first when shipping both:

```bash
./scripts/build-testflight.sh
./scripts/build-play.sh
```

Use command sessions with short initial yields, retain session IDs, and collect
final exit codes. Keep progress updates flowing. Investigate stalled commands
instead of imposing a timeout that kills a healthy build/upload. The known KGP
warning alone is not a failure.

Require fresh artifacts with intended embedded version/build and app ID. Select
the exact IPA; never upload `*.ipa`. Archive success does not prove IPA export.
For signing/export failures, inspect installed identities and matching valid
profiles and re-export the existing valid archive using the release reference.
Do not revoke/replace certificates or reuse a stale temporary export plist.

## 4. Upload binaries and store notes

Prepare separate canonical user-facing `en-US` notes for iOS and Android from
changes since the last shipped source, including already committed changes
before this bump. Each platform's notes must describe changes its users can
experience. Android notes must not mention Apple-only changes, such as iPhone
Duo layouts or iOS launch behavior; iOS notes must likewise omit Android-only
work. Shared app improvements can appear in both. Reuse applicable user-supplied
wording. Keep each UTF-8 text between 1 and 500 characters including bullets and
newlines. For a build-only release write a truthful brief note for each store.

Save exact text as `notes-ios.txt` and `notes-android.txt` in the release record.
Stage with `store_metadata.py prepare --ios-notes ... --android-notes ...`:
TestFlight's `testflight.txt` must contain the iOS notes, and the isolated Play
metadata must contain only `en-US/changelogs/<verified-version-code>.txt` with
the Android notes; no `default.txt` or stale notes. The legacy `--notes` input is
valid only when its text genuinely applies to both platforms. Use the helper
commands in the release reference.

After all requested builds/checks succeed, launch independent uploads concurrently
when both stores were requested. In Codex use `Promise.allSettled` for independent
launches, inspect every result, and retain each session ID. Builds share a cache;
store uploads do not. Source credential/path variables in each upload shell.

Require successful final exits and upload acknowledgements. Upload acceptance,
processing, and tester availability are distinct; report only verified state.
Keep Play on `internal`.

Use `scripts/upload-play.sh` for Play binary uploads, with the flags from the
release reference. Bare fastlane lacks the installed client's review-preservation
guard; the wrapper protects every commit attempt without changing installed gems.

After Apple accepts the IPA, the metadata helper publishes TestFlight What to Test
for the exact app/marketing version/build, waits for Apple to expose it, and reads
back exact iOS `en-US` text from staged `testflight.txt`. If unavailable, retain
upload success and report notes pending. For Play, upload the Android changelog
with the bundle and verify internal release text against `notes-android.txt`.
Preserve other locales, listing text, tester groups, and notification settings.

For reviewed changed Play screenshots, run the images-only helper: compare hashes
and order, validate an isolated edit, commit, then read back hashes/order. It
changes only manifest-listed `en-US` phone screenshots. Do not overlap notes and
screenshot Play edits; commits can invalidate one another. Keep team notes in chat
for the user to share.

The metadata helpers reject commits when another Play change is in review. Report
that blocker; do not cancel or resubmit unrelated review work automatically.

## Recovery

- One binary accepted: retry only failed selected store with unchanged verified
  artifact. Never upload the accepted binary again.
- Uncertain result: check remote state before retrying or bumping.
- Notes/screenshots failed or pending: retain binary/version/record and retry only
  missing metadata. The notes-only Play helper preserves locales/release fields.
- Duplicate version code: verify embedded bytes and remote acceptance first.
  A genuinely replacement binary needs a new monotonic build number.
- Apple train closed (90186): reconcile store state with today's version and obtain
  a versioning decision. Never silently date the release tomorrow.
- Credential/access failure: verify key/issuer pairing, private-key presence,
  package ID, and app access. Reuse setup; do not reinstall available fastlane or
  guess from multiple `.p8` files.
- Export compliance: retain `ITSAppUsesNonExemptEncryption=false` only while accurate.
- A fix changing app contents after one platform accepted a binary requires an
  explicit replacement release/version decision; do not claim source parity.

## 5. Commit, push, report

After every selected binary upload succeeds, stage intended shipped source/tests,
snapshot, screenshot PNGs/manifest, and `pubspec.yaml` by explicit path. Review
staged diff against built source. Never `git add .` / `-A`. Exclude credentials,
local properties, Pods, build output, and `.dart_tool`. Inspect `project.pbxproj`:
include intentional native changes; exclude incidental machine noise.

Follow recent commit style:

```text
<summary of the shipped change>; bump to <version>
```

Push only current branch to intended remote/upstream, without force. A ship
request authorizes push; editing this skill does not. If push fails after
commit/uploads, resume at push without rebuilding/re-uploading. Pending metadata
can be reported separately while committing successful binary releases; keep
their record until metadata completes.

Report version, commit, branch/push, and per-store binary/processing/notes/screenshot
state. Include exact notes separately for each store and 3–6 team bullets with
changes and testing details. Identify partial completion accurately. Do not message testers or promote
to production.
