#!/usr/bin/env bash
#
# Builds a release .ipa for TestFlight with the app's configuration baked in.
#
# WHY THIS EXISTS: TestFlight builds are NOT launched with `flutter run`, so the
# --dart-define values below must be compiled into the build. If you build
# without them, the app ships with no schedule URL / Discord link / event date.
#
# HOW TO USE:
#   1. Edit the three values below when the real schedule is published
#      (swap the gid=... numbers and the POC_EVENT_THURSDAY date).
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
SHEET_BASE="https://docs.google.com/spreadsheets/d/18HQ0b8jrP-iK_EVxPYffDvA3RBs6viX0/export?format=csv"
GID_THU_FRI="2027634205"
GID_SAT_SUN="1820056449"
DISCORD_URL="https://discord.gg/4GQgGnXN5"
EVENT_THURSDAY="2026-07-02"   # yyyy-MM-dd of the convention's Thursday
# ------------------------------------------------------------------------------

CSV_URLS="${SHEET_BASE}&gid=${GID_THU_FRI},${SHEET_BASE}&gid=${GID_SAT_SUN}"

echo "Building release .ipa for TestFlight..."
flutter build ipa \
  --dart-define=POC_SCHEDULE_CSV_URL="${CSV_URLS}" \
  --dart-define=POC_DISCORD_INVITE_URL="${DISCORD_URL}" \
  --dart-define=POC_EVENT_THURSDAY="${EVENT_THURSDAY}"

echo
echo "Done. Upload this file to App Store Connect (via Xcode Organizer or Transporter):"
echo "  $(pwd)/build/ios/ipa/*.ipa"
