---
name: ship
description: "Ship the current working-directory changes to BOTH TestFlight (iOS) and Google Play internal testers (Android). Bumps the +N build number in pubspec.yaml, runs the iOS and Android builds sequentially, uploads to both stores in parallel, commits the changed files + pubspec bump, pushes to remote, and writes release notes. Invoke when the user says something like 'ship this', 'ship it', 'commit and push this, add a new version number and push to testers', 'ship this to Play', 'ship to TestFlight', or any close variant."
---

# Ship to TestFlight + Play internal testers (PlayOnCon)

Fuller's one-shot flow for getting a change from working tree → both TestFlight and Play Console internal track in a single pass. Runs the whole pipeline without asking; the standing store-upload authorization applies to the push step.

Store credentials come from the `store-upload-credentials` memory — don't re-ask for the ASC Key ID / Issuer ID / package name / JSON path.

## Preconditions to check silently

- `git status --short` shows only intentional changes (no stray files you don't recognize — if you see any, stop and ask).
- `scripts/.env.local` exists (both build scripts source it).
- `~/.playconsole/playoncon-publisher.json` exists.
- `~/.appstoreconnect/private_keys/AuthKey_<key-id>.p8` exists.

If any debug `flutter run` task is still running in the background, `TaskStop` it before building — Gradle and `flutter run` both share `.dart_tool` and will collide.

## Step 1 — Set the version

The version string is `YYYY.M.D+N` — marketing = **today's date**, build number = monotonically incrementing across ships (never resets on a date change). Run `date +%Y.%-n.%-d` to get today's date in the exact format (no zero-padding on month/day; `2026.7.4`, not `2026.07.04`).

Read `pubspec.yaml`, then:

- **If the marketing date matches today**: increment `+N`.
  `version: 2026.7.4+25` → `version: 2026.7.4+26`
- **If the marketing date is in the past** (a day or more old): set marketing to today's date AND increment `+N`.
  `version: 2026.7.2+24` → `version: 2026.7.4+25`

The `+N` build number is monotonic across the whole app — TestFlight and Play both require it to strictly increase, regardless of whether the marketing version changed. Never reset it. Never bump marketing to a *future* date, and never bump marketing backward.

## Step 2 — Build both artifacts (sequentially)

Both builds share `.dart_tool`, so run them one at a time. iOS first — signing issues surface faster than Gradle failures.

```bash
./scripts/build-testflight.sh    # ~1–2 min, produces build/ios/ipa/*.ipa
./scripts/build-play.sh          # ~1–2 min, produces build/app/outputs/bundle/release/app-release.aab
```

Run each as a background task with a 10-minute timeout. Success lines:

- iOS: `✓ Built IPA to build/ios/ipa (~30MB)`
- Android: `✓ Built build/app/outputs/bundle/release/app-release.aab (~55MB)`

The Kotlin Gradle Plugin (KGP) warning on Android is benign — ignore it.

## Step 3 — Upload to both stores (in parallel)

Different APIs, no shared state — dispatch both uploads in the same message as parallel background tasks.

### iOS → TestFlight

```bash
xcrun altool --upload-app \
  --type ios \
  -f build/ios/ipa/*.ipa \
  --apiKey <from store-upload-credentials memory> \
  --apiIssuer <from store-upload-credentials memory>
```

Long-running (~2 min normal, up to 25 min if Apple's API is flaky — altool retries on transient 500s, don't kill it). Give this background task a **20-minute timeout**. Success line:

```
UPLOAD SUCCEEDED with no errors
```

Build appears in TestFlight after Apple processes it (typically 10–30 min after upload completes).

### Android → Play internal

```bash
fastlane supply \
  --aab build/app/outputs/bundle/release/app-release.aab \
  --package_name com.fuller.playoncon \
  --json_key ~/.playconsole/playoncon-publisher.json \
  --track internal \
  --skip_upload_metadata true \
  --skip_upload_changelogs true \
  --skip_upload_images true \
  --skip_upload_screenshots true
```

Typical end-to-end ~30 s. Success line:

```
Successfully finished the upload to Google Play
```

## Step 4 — Commit and push

Only after **both** uploads have succeeded — never commit a version bump that only shipped to one store, because the next ship attempt will re-bump and skip the failed store.

Stage by **explicit path** — never `git add .` / `-A`. Include:

- Every file listed by `git status --short` that was part of what shipped (source + test edits).
- `pubspec.yaml`.

Exclude machine-specific noise: `ios/Runner.xcodeproj/project.pbxproj` (unless the user says otherwise), `android/local.properties`, `Pods/`, `.dart_tool/`.

Commit message: one line summarizing what shipped, ending with `; bump to <version>`. Follow the repo's existing style (see `git log --oneline -5`):

```
<short summary of the change>; bump to 2026.7.2+23
```

If there's a compelling "why," add a body paragraph — but keep it tight. Then:

```bash
git push
```

Standing authorization applies — no need to ask before pushing. Push only the current branch, never force-push.

## Step 5 — Write release notes

At the end of the run, emit release notes in two forms so Fuller can paste either into Play Console / App Store Connect (both have per-build "What to test" fields) or share with the team:

**Short (store consoles):** bullet list, under 500 chars, user-facing language ("Rocky Horror now starts at 11:30 PM", not "parser fix"). Focus on what the tester will *see or feel*, not the implementation.

**Longer (team/internal):** 3–6 bullets with the technical framing — what changed, why, and any behavior detail that matters when triaging feedback.

Derive both from the commit body plus the file diff — don't invent features. If the change is purely mechanical (build number only), say so and skip the short form.

## Failure modes to recognize fast

- **Edit rejected because pubspec.yaml wasn't read this turn** → Read it, then Edit. Common when resuming from a summary.
- **Debug run still holds the build cache** → TaskStop the flutter run task before invoking either build script.
- **fastlane "APK specifies a version code that has already been used"** → the +N didn't get baked in; re-verify pubspec and rerun the build.
- **fastlane "Package not found"** → someone changed the package name; the current value is `com.fuller.playoncon`.
- **altool "Invalid Pre-Release Train. The train version 'X.Y.Z' is closed"** (error 90186) → Apple has closed that marketing-version train. Since the skill sets marketing to today's date on every ship, this only fires when re-shipping on the same day after Apple has already closed today's train. Bump marketing forward by one day (`2026.7.4` → `2026.7.5`) and rebuild both — flag this to the user in the commit message since it's an owner-visible version drift from the actual calendar date.
- **altool 401 / "App not found"** → wrong ASC Key ID + Issuer ID pair, or the `.p8` file is missing. The credentials memory has the correct values.
- **One store succeeded, the other failed** → do NOT commit yet. Fix the failure, re-upload only the failed store using the already-built artifact (no rebuild needed unless the artifact is stale), then commit once both are up.
- **iOS export-compliance halts the build** → `ITSAppUsesNonExemptEncryption=false` should already be set in `ios/Runner/Info.plist`; if it's missing, add it before rebuilding.
