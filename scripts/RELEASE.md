# PlayOnCon release tools

The ship skills in `.agents/skills/ship/` and `.claude/skills/ship/` use these
helpers. Updating tools, capturing images, or refreshing the local schedule does
not upload an app. A ship request starts the store/commit/push workflow.

## Configuration and preflight

`release-config.sh` is the shared source for build and import configuration.
Public values have existing app defaults; overrides and credential metadata live
in gitignored `scripts/.env.local`. The example file documents the supported
settings. Both build scripts still bake the values through Dart defines.

Run snippets that source `release-config.sh` in Bash; it uses Bash arrays.
The executable build/import wrappers already select Bash. For an inline Codex
command, select `/bin/bash` explicitly instead of the user's default shell.
If macOS Java launchers cannot find a runtime, use the existing Android Studio
runtime through command-scoped `JAVA_HOME` and `PATH` before Android preflight
and build; do not reinstall Java or mistake that launcher failure for a bad key.

Store metadata settings are `ASC_KEY_ID`, `ASC_ISSUER_ID`, optional
`ASC_PRIVATE_KEY_PATH`, and optional `POC_PLAY_JSON_KEY`. The Apple key defaults
to `~/.appstoreconnect/private_keys/AuthKey_<ID>.p8`; the Play service-account
file defaults to `~/.playconsole/playoncon-publisher.json`. Do not print private
keys, passwords, service-account contents, or access tokens. Keep the local env
file private (mode 0600); it contains metadata/paths, never private-key contents.

When IDs are missing, reuse values already supplied in this task or recover the
exact pair from a previous successful PlayOnCon release task. In Codex, use
`list_threads` / `read_thread`, filtering output to release commands/results.
Verify app access before persisting recovered metadata. Multiple `.p8` files do
not identify the right pair. Ask only when local setup and successful release
history cannot resolve it; no Claude memory service is required.

Before bumping for a release, run the selected preflights:

```bash
python3 scripts/release_preflight.py ios --upload
python3 scripts/release_preflight.py android --upload
```

Build-only preflight omits `--upload`. Android checks the actual keystore path
relative to `android/app`, its private-key alias, and tools/SDK; missing signing
never falls through to a debug-signed release. iOS checks selected Xcode and usable
local signing identities; final export and artifact checks still establish success.

If fastlane is absent from PATH, inspect `gem environment gempath` and existing
Ruby gem `bin/fastlane` executables, then add the verified working bin directories
to that command's PATH. Do not reinstall an existing working tool. Use
`FASTLANE_SKIP_UPDATE_CHECK=1` to keep update banners from obscuring upload results.
Read final exit codes and acknowledgements, not just the last log line.

## Schedule and screenshots

```bash
./scripts/refresh-schedule.sh
./scripts/capture-store-assets.sh
python3 scripts/store_screenshots.py plan
```

Refresh uses Sheets API grids and merge ranges for every configured gid. It
validates tabs, Thursday/date ranges, nonempty events, and existing snapshot
counts before an atomic replacement. Read venue matching and effective description
coverage. A reduction exceeding 20% requires investigation before explicitly using
`--allow-count-drop`; do not routinely pass that flag. `--grid-input` can replay
a saved native API response for offline importer testing.

Screenshot examples use an independent frozen fixture, clock, and provider state.
The listing manifest orders five opaque RGB 1080×1920 PNGs; dark previews are
local QA assets. Review both appearances. Do not regenerate the fixture as an
incidental result of a schedule refresh. See
[the listing guide](../design/google-play/README.md) for screen order and capture details.

`plan` checks files, format/dimensions, and hashes without credentials or networking.
Other actions use only `en-US` phone screenshots:

```bash
python3 scripts/store_screenshots.py check
python3 scripts/store_screenshots.py validate
python3 scripts/store_screenshots.py upload
```

`check` compares remote hashes/order and discards its temporary edit; exit 2 means
different images, not a verified match. `validate` stages the replacements and
validates, then discards without publishing. `upload` skips an identical set,
otherwise stages and validates before committing, and reads back SHA256 hashes
and order. It does not alter feature graphics, other image types/locales, text,
notes, or binaries. This requires Play **Manage store presence**, independently
of binary release permissions. Do not overlap this edit with notes or supply edits.

Metadata commits explicitly use `ERROR_IF_IN_REVIEW`. If Play already has changes
in review, report the blocker and wait or obtain the user's decision; never cancel
or resubmit an unrelated review to finish notes/screenshots.

An uncertain commit triggers remote readback, not repeated uploads. If verification
fails, record the partial result and run `check` before retrying. Initial setup
and resumed uploads also need remote comparison even when local PNGs are unchanged.

API reference: [Google Play images](https://developers.google.com/android-publisher/api-ref/rest/v3/edits.images).

## Fresh verified artifacts and release records

```bash
./scripts/build-testflight.sh
./scripts/build-play.sh
```

Run sequentially; both use `.dart_tool`. Each script records its start time,
requires fresh output, verifies embedded app ID/marketing version/build number,
and writes a version-specific receipt in `build/releases/<version>/`:
`ios-artifact.json` and `android-artifact.json`. Receipts contain exact absolute
paths, SHA256, size, and mtime. Android also checks bundle signing integrity.
An xcarchive with no fresh IPA is a failure even if Flutter's archive command
exited successfully. Old or multiple fresh IPAs are rejected.

Keep per-platform canonical notes and per-store results alongside these receipts.
Save the built source revision and intended diff before build (including shipped untracked
files); leave credentials out. Record version, source, artifacts, upload
acknowledgements, processing, notes, screenshots, commit, and push independently.
For resumption, establish source/artifact identity before reusing output; the
receipts alone do not prove that current source is unchanged.

Inspect an existing artifact explicitly when recovering:

```bash
python3 scripts/verify_release_artifacts.py ios \
  --artifact "$POC_IPA_PATH" --version "$POC_VERSION" --id com.fuller.playoncon
python3 scripts/verify_release_artifacts.py android \
  --artifact "$POC_AAB_PATH" --version "$POC_VERSION" --id com.fuller.playoncon
```

### Recover IPA export from a valid archive

Inspect `security find-identity -v -p codesigning` and unexpired matching profiles
in `~/Library/Developer/Xcode/UserData/Provisioning Profiles/`. Resolve team ID,
distribution certificate SHA-1, and profile UUID from the actual installed setup;
check bundle ID, certificate match, and expiration. Do not copy BurlyCon's IDs.
Use a fresh temporary export options plist with:

- `method = app-store-connect`
- `signingStyle = manual`
- the resolved `teamID` and `signingCertificate`
- `provisioningProfiles = {com.fuller.playoncon: <matching-profile-UUID>}`
- `manageAppVersionAndBuildNumber = false`
- `stripSwiftSymbols = true`

```bash
xcodebuild -exportArchive \
  -archivePath build/ios/archive/Runner.xcarchive \
  -exportPath build/ios/ipa \
  -exportOptionsPlist "$POC_EXPORT_OPTIONS"
```

Validate the newly exported IPA against the established version and record its
exact path/hash. If no valid profile exists, use verified app/team credentials to
create/download a profile for the existing bundle ID and installed distribution
certificate as part of the authorized release. Never revoke or replace certificates.
An app-content change after one store accepted a binary requires an explicit
replacement-release decision, rather than exporting a different app under the old record.

## Canonical notes and uploads

Set `POC_VERSION` from the established release, never bump it as part of metadata
recovery. Write user-facing notes from all changes since the last shipped source
as `build/releases/<version>/notes-ios.txt` and `notes-android.txt`. Each store's
notes must describe changes experienced on its platform: Android notes must not
mention Apple-only work such as iPhone Duo layouts or iOS launch behavior, and
iOS notes must omit Android-only work. Shared app improvements may appear in
both. Keep each file to 1–500 UTF-8 characters including newlines.
Stage the two platform texts independently:

```bash
POC_RECORD="build/releases/${POC_VERSION}"
python3 scripts/store_metadata.py prepare \
  --version "$POC_VERSION" \
  --ios-notes "$POC_RECORD/notes-ios.txt" \
  --android-notes "$POC_RECORD/notes-android.txt" \
  --output "$POC_RECORD/metadata"
```

The output contains iOS notes in `testflight.txt` and Android notes in only the
version-specific `play/en-US/changelogs/<N>.txt`. The legacy `--notes <file>`
option is retained for genuinely shared notes that apply to both platforms;
do not use it to copy Apple-only changes into Android notes or vice versa.
The helper rejects an output directory containing
another version or unrelated files; use an isolated path, not downloaded listing
metadata or `default.txt`. Reusing the same release's staging directory is idempotent.

After all selected builds/checks succeed, run binary uploads in independent
command sessions. Source configuration and re-establish path variables in each
shell; other sessions do not share them. Exact IPA path comes from its receipt:

```bash
source scripts/release-config.sh
POC_RECORD="build/releases/${POC_VERSION}"
POC_IPA_PATH="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["artifact"])' "$POC_RECORD/ios-artifact.json")"
xcrun altool --upload-app --type ios --file "$POC_IPA_PATH" \
  --apiKey "$ASC_KEY_ID" --apiIssuer "$ASC_ISSUER_ID"
```

altool expects the `.p8` in its standard private-key directory. For a custom
private-key path, establish the installed tool's supported key-directory option
before uploading. Require `UPLOAD SUCCEEDED with no errors` and final exit 0.
Apple may retry transient errors for many minutes; observe its progress rather
than killing it on an arbitrary short timeout. Processing/availability is separate.

```bash
source scripts/release-config.sh
POC_RECORD="build/releases/${POC_VERSION}"
./scripts/upload-play.sh \
  --aab build/app/outputs/bundle/release/app-release.aab \
  --package_name "$POC_PACKAGE_NAME" --json_key "$POC_PLAY_JSON_KEY" \
  --track internal --metadata_path "$POC_RECORD/metadata/play" \
  --skip_upload_metadata true --skip_upload_changelogs false \
  --skip_upload_images true --skip_upload_screenshots true
```

Require final exit 0 and `Successfully finished the upload to Google Play`.
The notes flag is independent of listing metadata.
[Fastlane changelog reference](https://docs.fastlane.tools/actions/upload_to_play_store/#changelogs-whats-new).

Use the checked-in upload wrapper rather than bare `fastlane supply`. It applies
`ERROR_IF_IN_REVIEW` at the installed Google client's commit boundary, including
fastlane's recovery attempts, and stops before upload if the client cannot support
the guard. It does not modify installed gems. A review conflict leaves the existing
review intact and requires a later retry or the user's decision.

### Publish/read back notes or recover only metadata

```bash
python3 scripts/store_metadata.py testflight \
  --version "$POC_VERSION" --notes "$POC_RECORD/metadata/testflight.txt" \
  --wait-seconds 1200
python3 scripts/store_metadata.py play \
  --version "$POC_VERSION" --notes "$POC_RECORD/notes-android.txt" --read-only
```

TestFlight resolves the app from its bundle ID and matches marketing train and
build number. It waits at 30-second intervals for a valid processed build, creates
or patches `en-US` What to Test from staged iOS `testflight.txt`, and reads back
exact text. Run in a command session and keep the user updated. If Apple is still
processing, record notes pending and
rerun later without another bump/build/binary upload. Other locales remain intact.
[Apple localization reference](https://developer.apple.com/documentation/appstoreconnectapi/beta-build-localizations).

Play `--read-only` verifies the exact version code on `internal` and compares its
notes with `notes-android.txt`, never the iOS `testflight.txt`. If only its notes
need repair, rerun the same command without `--read-only`: it reads the existing
release, changes only the chosen locale's text, preserves other locales/releases
and all release fields, validates, commits, and reads back a fresh edit. No AAB is
sent. Both helpers skip matching notes and avoid selecting a generic latest build.

If an upload or metadata commit has an uncertain result, check remote state before
retrying. Do not change versions or resubmit accepted binaries to repair notes,
screenshots, or a push. Report each result separately, then finish only pending work.

## Local verification

```bash
python3 -m unittest discover -s scripts/tests -v
flutter test
flutter analyze --no-pub
```

These cover artifact identity/freshness, signing preflight, notes/locale preservation,
metadata retry behavior, screenshot transaction isolation, and the app/importer.
They do not perform a live upload or establish actual store permissions.
