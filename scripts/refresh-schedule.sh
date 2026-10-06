#!/usr/bin/env bash
# Refresh the exact merge-aware source used in release builds.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/release-config.sh"
export SHEETS_API_KEY SHEET_ID SHEET_GIDS EVENT_THURSDAY
cd "$REPO_ROOT"
exec dart run scripts/import_schedule.dart "$@"
