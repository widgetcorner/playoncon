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
# Spreadsheet is addressed by tab NAME (not gid) because the source workbook is
# an uploaded .xlsx — gids aren't exposed in its share HTML. gviz/tq returns
# CSV by visible tab name; %20=" " and %2B="+" url-encoded.
SHEET_ID="1IFsCk650WKiaJ0FDiPOmPNCg1Ysyc6FF"
SHEET_BASE="https://docs.google.com/spreadsheets/d/${SHEET_ID}/gviz/tq?tqx=out:csv"
SHEET_VIEW_URL="https://docs.google.com/spreadsheets/d/${SHEET_ID}/edit?usp=sharing"
TAB_THU_FRI="2026%20Thursday%20%2B%20Friday"
TAB_SAT_SUN="2026%20Saturday%20%2B%20Sunday"
DISCORD_URL="https://discord.gg/4GQgGnXN5"
PROGRAM_URL="https://docs.google.com/document/d/1zmLj-VqwnR8OnfvF13YAobTkbNGy4lvbv-DVRyfOMyI/edit?usp=sharing"
EVENT_THURSDAY="2026-07-02"   # yyyy-MM-dd of the convention's Thursday
SUPABASE_URL="https://yfjnurscnzjvjvhrpgwb.supabase.co"
SUPABASE_PUBLISHABLE_KEY="sb_publishable__2euDEwhjmzgYiyY6RI21w_SLPw1qDw"
# ------------------------------------------------------------------------------

CSV_URLS="${SHEET_BASE}&sheet=${TAB_THU_FRI},${SHEET_BASE}&sheet=${TAB_SAT_SUN}"

# Read the version: line from pubspec.yaml so the Info tab's version string is
# always in sync with what Play Console sees (replaces package_info_plus).
APP_VERSION=$(awk '/^version: /{print $2; exit}' pubspec.yaml)

echo "Building release .aab for Google Play..."
flutter build appbundle \
  --dart-define=POC_SCHEDULE_CSV_URL="${CSV_URLS}" \
  --dart-define=POC_SCHEDULE_VIEW_URL="${SHEET_VIEW_URL}" \
  --dart-define=POC_DISCORD_INVITE_URL="${DISCORD_URL}" \
  --dart-define=POC_PROGRAM_URL="${PROGRAM_URL}" \
  --dart-define=POC_EVENT_THURSDAY="${EVENT_THURSDAY}" \
  --dart-define=POC_SUPABASE_URL="${SUPABASE_URL}" \
  --dart-define=POC_SUPABASE_PUBLISHABLE_KEY="${SUPABASE_PUBLISHABLE_KEY}" \
  --dart-define=POC_APP_VERSION="${APP_VERSION}"

echo
echo "Done. Upload this file to the Play Console testing track:"
echo "  $(pwd)/build/app/outputs/bundle/release/app-release.aab"
