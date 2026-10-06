#!/usr/bin/env bash
# Render real Android screens from fixed fixture data. No credentials or network.
set -euo pipefail
CAPTURE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${CAPTURE_ROOT}"
flutter test --no-pub \
  --dart-define-from-file=test/fixtures/screenshot-config.json \
  tool/capture_store_listing_test.dart "$@"
