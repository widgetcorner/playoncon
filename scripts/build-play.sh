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
# Spreadsheet tabs are addressed by gid (the stable per-tab id) via the CSV
# export endpoint. The old gviz/tq "&sheet=<tab name>" form silently falls back
# to the FIRST tab whenever the name doesn't match exactly (e.g. a tab rename),
# which made the second tab's events disappear from the app. gid is immune to
# renames. Find a tab's gid in the sheet URL when that tab is selected
# (…/edit#gid=NNN).
# The schedule must be a NATIVE Google Sheet, not an uploaded .xlsx — the
# Sheets API's merge-aware endpoint returns FAILED_PRECONDITION on Office
# files, which meant multi-hour events (Nidhogg, Malevolent) came back as
# 1-hour blocks in earlier builds. Wes converted the original .xlsx via
# File → Save as Google Sheets; the file ID below is the native copy.
SHEET_ID="1uMrBl9oFz9CWTfJX5eET-3bguERKpZ4IahPbFdpFqT0"
SHEET_EXPORT="https://docs.google.com/spreadsheets/d/${SHEET_ID}/export?format=csv"
SHEET_VIEW_URL="https://docs.google.com/spreadsheets/d/${SHEET_ID}/edit?usp=sharing"
GID_THU_FRI="2027634205"   # 2026 Thursday + Friday
GID_SAT_SUN="1820056449"   # 2026 Saturday + Sunday
DISCORD_URL="https://discord.gg/4GQgGnXN5"
PROGRAM_URL="https://drive.google.com/file/d/1sx46MEfKEBswAv_wDgk3Ly1c6PX-ECIB/view?usp=sharing"
EVENT_THURSDAY="2026-07-02"   # yyyy-MM-dd of the convention's Thursday
SUPABASE_URL="https://yfjnurscnzjvjvhrpgwb.supabase.co"
# ------------------------------------------------------------------------------

# Secrets live in scripts/.env.local (git-ignored). Rotate keys there, not here.
# See scripts/.env.local.example for the required variables.
ENV_FILE="$(dirname "$0")/.env.local"
if [ ! -f "${ENV_FILE}" ]; then
  echo "ERROR: ${ENV_FILE} not found." >&2
  echo "  Copy scripts/.env.local.example to scripts/.env.local and fill it in." >&2
  exit 1
fi
# shellcheck disable=SC1090
source "${ENV_FILE}"
: "${SHEETS_API_KEY:?SHEETS_API_KEY must be set in scripts/.env.local}"
: "${SUPABASE_PUBLISHABLE_KEY:?SUPABASE_PUBLISHABLE_KEY must be set in scripts/.env.local}"

CSV_URLS="${SHEET_EXPORT}&gid=${GID_THU_FRI},${SHEET_EXPORT}&gid=${GID_SAT_SUN}"
SHEET_GIDS="${GID_THU_FRI},${GID_SAT_SUN}"

# Read the version: line from pubspec.yaml so the Info tab's version string is
# always in sync with what Play Console sees (replaces package_info_plus).
APP_VERSION=$(awk '/^version: /{print $2; exit}' pubspec.yaml)

echo "Building release .aab for Google Play..."
flutter build appbundle \
  --dart-define=POC_SHEETS_API_KEY="${SHEETS_API_KEY}" \
  --dart-define=POC_SHEET_ID="${SHEET_ID}" \
  --dart-define=POC_SHEET_GIDS="${SHEET_GIDS}" \
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
