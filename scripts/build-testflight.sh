#!/usr/bin/env bash
# Build and verify one fresh TestFlight IPA. An archive without an export fails.
set -euo pipefail
source "$(dirname "$0")/release-config.sh"
cd "${RELEASE_PROJECT_ROOT}"
release_require_config
release_dart_defines
python3 scripts/release_preflight.py ios
STARTED_AT="$(python3 -c 'import time; print(time.time())')"
echo "Building release IPA for TestFlight..."
flutter build ipa "${POC_DART_DEFINES[@]}" "$@"
python3 scripts/verify_release_artifacts.py ios \
  --ipa-dir build/ios/ipa --since "${STARTED_AT}" \
  --version "${APP_VERSION}" --id "${POC_BUNDLE_ID}" \
  --receipt "build/releases/${APP_VERSION}/ios-artifact.json"
