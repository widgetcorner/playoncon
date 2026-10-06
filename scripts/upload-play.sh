#!/usr/bin/env bash
# Supply's usual flags, guarded against cancelling any pending Google review.
set -euo pipefail
PLAY_UPLOAD_SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
export FASTLANE_SKIP_UPDATE_CHECK=1
export FASTLANE_HIDE_CHANGELOG=1
export FASTLANE_DISABLE_ANIMATION=1
exec ruby "${PLAY_UPLOAD_SCRIPT_DIR}/upload_play.rb" "$@"
