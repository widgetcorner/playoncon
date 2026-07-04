---
name: ship
description: "Ship the current working-directory changes to Google Play internal testers. Bumps the +N build number in pubspec.yaml, runs scripts/build-play.sh, uploads the .aab to the Play internal track, commits the changed files + pubspec bump, pushes to remote, and writes release notes. Invoke when the user says something like 'ship this', 'ship it', 'commit and push this, add a new version number and push to android internal testers', 'ship this to Play', or any close variant. Android-only for now — Apple case 102924568243 has cleared, so this can grow (or defer to flutter-store-upload for) an iOS arm."
---

# Ship to Play internal testers (PlayOnCon)

Fuller's one-shot flow for getting a change from working tree → Play Console internal track. Runs the whole pipeline without asking; the standing store-upload authorization applies to the push step.

## Preconditions to check silently

- `git status --short` shows only intentional changes (no stray files you don't recognize — if you see any, stop and ask).
- `scripts/.env.local` exists (build script sources it).
- `~/.playconsole/playoncon-publisher.json` exists.

If any debug `flutter run` task is still running in the background, `TaskStop` it before building — Gradle and `flutter run` share `.dart_tool` and will collide.

## Step 1 — Bump build number

Read `pubspec.yaml`, find the `version:` line, increment the integer after the `+`:

```
version: 2026.7.1+19  →  version: 2026.7.1+20
```

Never bump the marketing portion (`2026.7.1`) unless the user explicitly asks — that's for user-visible releases.

## Step 2 — Build the .aab

```bash
./scripts/build-play.sh
```

Long-running (~1–2 min). Run as a background task with a 10-minute timeout. Success line:

```
✓ Built build/app/outputs/bundle/release/app-release.aab (~55MB)
```

The Kotlin Gradle Plugin (KGP) warning is benign — ignore it.

## Step 3 — Upload to Play internal

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

Values pulled from the `store-upload-credentials` memory. Success line:

```
Successfully finished the upload to Google Play
```

If it fails with "version code already used", the +N bump didn't take — re-check pubspec and rebuild.

## Step 4 — Commit and push

Stage by **explicit path** — never `git add .` / `-A`. Include:

- Every file listed by `git status --short` that was part of what shipped (source + test edits).
- `pubspec.yaml`.

Exclude machine-specific noise: `ios/Runner.xcodeproj/project.pbxproj` (unless the user says otherwise), `android/local.properties`, `Pods/`, `.dart_tool/`.

Commit message: one line summarizing what shipped, ending with `; bump to <version>`. Follow the repo's existing style (see `git log --oneline -5`):

```
<short summary of the change>; bump to 2026.7.1+20
```

If there's a compelling "why," add a body paragraph — but keep it tight. Then:

```bash
git push
```

Standing authorization applies — no need to ask before pushing. Push only the current branch, never force-push.

## Step 5 — Write release notes

At the end of the run, emit release notes in two forms so Fuller can paste either into Play Console (500-char limit) or share with the team:

**Short (Play Console):** bullet list, under 500 chars, user-facing language ("Rocky Horror now starts at 11:30 PM", not "parser fix"). Focus on what the tester will *see or feel*, not the implementation.

**Longer (team/internal):** 3–6 bullets with the technical framing — what changed, why, and any behavior detail that matters when triaging feedback.

Derive both from the commit body plus the file diff — don't invent features. If the change is purely mechanical (build number only), say so and skip the short form.

## Failure modes to recognize fast

- **Edit rejected because pubspec.yaml wasn't read this turn** → Read it, then Edit. Common when resuming from a summary.
- **Debug run still holds the build cache** → TaskStop the flutter run task before invoking `build-play.sh`.
- **fastlane "APK specifies a version code that has already been used"** → the +N didn't get baked in; re-verify pubspec and rerun the build.
- **fastlane "Package not found"** → someone changed the package name; the current value is `com.fuller.playoncon`.

## Why Android-only (for now)

Apple case 102924568243 (individual→org migration) previously locked the iOS cert portal — that block was cleared on 2026-07-01 and TestFlight uploads work again. This skill hasn't grown an iOS arm yet, so for parallel TestFlight + Play uploads use the general `flutter-store-upload` skill instead. If invoked as-is it still ships Android-only.
