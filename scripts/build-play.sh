#!/usr/bin/env bash
#
# Builds a release Android App Bundle (.aab) for Google Play, with the app's
# configuration baked in (same reasoning as build-testflight.sh: Play builds
# aren't launched with `flutter run`, so --dart-define values must be compiled
# in).
#
# PREREQUISITES:
#   - Android SDK installed (Android Studio) and `flutter doctor` shows the
#     Android toolchain with a checkmark.
#   - android/key.properties + android/app/upload-keystore.jks present (the
#     upload signing key). These are gitignored — back them up safely.
#
# HOW TO USE:
#   1. Edit the values below when the real schedule is published.
#   2. From the project root, run:  ./scripts/build-play.sh
#   3. Upload the printed .aab to the Play Console testing track.
#
# NOTE: bump the build number in pubspec.yaml (after the "+") before each upload.

set -euo pipefail

# --- EDIT THESE WHEN THE 2026 SCHEDULE IS LIVE ---------------------------------
SHEET_BASE="https://docs.google.com/spreadsheets/d/18HQ0b8jrP-iK_EVxPYffDvA3RBs6viX0/export?format=csv"
GID_THU_FRI="2027634205"
GID_SAT_SUN="1820056449"
DISCORD_URL="https://discord.gg/4GQgGnXN5"
EVENT_THURSDAY="2026-07-02"   # yyyy-MM-dd of the convention's Thursday
# ------------------------------------------------------------------------------

CSV_URLS="${SHEET_BASE}&gid=${GID_THU_FRI},${SHEET_BASE}&gid=${GID_SAT_SUN}"

echo "Building release .aab for Google Play..."
flutter build appbundle \
  --dart-define=POC_SCHEDULE_CSV_URL="${CSV_URLS}" \
  --dart-define=POC_DISCORD_INVITE_URL="${DISCORD_URL}" \
  --dart-define=POC_EVENT_THURSDAY="${EVENT_THURSDAY}"

echo
echo "Done. Upload this file to the Play Console testing track:"
echo "  $(pwd)/build/app/outputs/bundle/release/app-release.aab"
