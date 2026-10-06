#!/usr/bin/env bash
# Build only with the actual upload key, then verify the fresh signed bundle.
set -euo pipefail
source "$(dirname "$0")/release-config.sh"
cd "${RELEASE_PROJECT_ROOT}"
release_require_config
release_dart_defines
python3 scripts/release_preflight.py android
STARTED_AT="$(python3 -c 'import time; print(time.time())')"
echo "Building release Android App Bundle for Play internal testers..."
flutter build appbundle "${POC_DART_DEFINES[@]}" "$@"
python3 scripts/verify_release_artifacts.py android \
  --artifact build/app/outputs/bundle/release/app-release.aab --since "${STARTED_AT}" \
  --version "${APP_VERSION}" --id "${POC_PACKAGE_NAME}" \
  --receipt "build/releases/${APP_VERSION}/android-artifact.json"
