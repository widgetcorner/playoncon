#!/usr/bin/env bash
#
# Builds a release .ipa for TestFlight with the app's configuration baked in.
#
# WHY THIS EXISTS: TestFlight builds are NOT launched with `flutter run`, so the
# --dart-define values below must be compiled into the build. If you build
# without them, the app ships with no schedule URL / Discord link / event date.
#
# HOW TO USE:
#   1. Edit the values below if the spreadsheet ID, tab names, Discord URL,
#      or Thursday date change.
#   2. In Terminal, from the project root, run:
#        ./scripts/build-testflight.sh
#   3. When it finishes, the file to upload is printed at the end
#      (build/ios/ipa/playoncon.ipa).
#
# NOTE: increment the build number in pubspec.yaml (the part after the "+",
# e.g. 1.0.0+1 -> 1.0.0+2) before EACH upload, or App Store Connect rejects it
# as a duplicate.

set -euo pipefail

# --- EDIT THESE WHEN THE 2026 SCHEDULE IS LIVE ---------------------------------
# Spreadsheet tabs are addressed by gid (the stable per-tab id) via the CSV
# export endpoint. The old gviz/tq "&sheet=<tab name>" form silently falls back
# to the FIRST tab whenever the name doesn't match exactly (e.g. a tab rename),
# which made the second tab's events disappear from the app. gid is immune to
# renames. Find a tab's gid in the sheet URL when that tab is selected
# (…/edit#gid=NNN).
SHEET_ID="1IFsCk650WKiaJ0FDiPOmPNCg1Ysyc6FF"
SHEET_EXPORT="https://docs.google.com/spreadsheets/d/${SHEET_ID}/export?format=csv"
SHEET_VIEW_URL="https://docs.google.com/spreadsheets/d/${SHEET_ID}/edit?usp=sharing"
GID_THU_FRI="2027634205"   # 2026 Thursday + Friday
GID_SAT_SUN="1820056449"   # 2026 Saturday + Sunday
DISCORD_URL="https://discord.gg/4GQgGnXN5"
PROGRAM_URL="https://drive.google.com/file/d/1sx46MEfKEBswAv_wDgk3Ly1c6PX-ECIB/view?usp=sharing"
EVENT_THURSDAY="2026-07-02"   # yyyy-MM-dd of the convention's Thursday
SUPABASE_URL="https://yfjnurscnzjvjvhrpgwb.supabase.co"
SUPABASE_PUBLISHABLE_KEY="sb_publishable__2euDEwhjmzgYiyY6RI21w_SLPw1qDw"
# ------------------------------------------------------------------------------

CSV_URLS="${SHEET_EXPORT}&gid=${GID_THU_FRI},${SHEET_EXPORT}&gid=${GID_SAT_SUN}"

# Read the version: line from pubspec.yaml so the Info tab's version string is
# always in sync with what App Store Connect sees (replaces package_info_plus).
APP_VERSION=$(awk '/^version: /{print $2; exit}' pubspec.yaml)

echo "Building release .ipa for TestFlight..."
flutter build ipa \
  --dart-define=POC_SCHEDULE_CSV_URL="${CSV_URLS}" \
  --dart-define=POC_SCHEDULE_VIEW_URL="${SHEET_VIEW_URL}" \
  --dart-define=POC_DISCORD_INVITE_URL="${DISCORD_URL}" \
  --dart-define=POC_PROGRAM_URL="${PROGRAM_URL}" \
  --dart-define=POC_EVENT_THURSDAY="${EVENT_THURSDAY}" \
  --dart-define=POC_SUPABASE_URL="${SUPABASE_URL}" \
  --dart-define=POC_SUPABASE_PUBLISHABLE_KEY="${SUPABASE_PUBLISHABLE_KEY}" \
  --dart-define=POC_APP_VERSION="${APP_VERSION}"

echo
echo "Done. Upload this file to App Store Connect (via Xcode Organizer or Transporter):"
echo "  $(pwd)/build/ios/ipa/*.ipa"
