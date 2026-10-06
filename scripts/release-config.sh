#!/usr/bin/env bash
# Shared build, importer, and store metadata configuration. Source this file.
# Public defaults live here; credentials and optional overrides live in .env.local.

RELEASE_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RELEASE_PROJECT_ROOT="$(cd "${RELEASE_SCRIPT_DIR}/.." && pwd)"
RELEASE_ENV_FILE="${POC_RELEASE_ENV_FILE:-${RELEASE_SCRIPT_DIR}/.env.local}"
if [[ -f "${RELEASE_ENV_FILE}" ]]; then
  # shellcheck disable=SC1090
  source "${RELEASE_ENV_FILE}"
fi

: "${SHEET_ID:=1uMrBl9oFz9CWTfJX5eET-3bguERKpZ4IahPbFdpFqT0}"
: "${SHEET_GIDS:=2027634205,1820056449}"
: "${SHEET_VIEW_URL:=https://docs.google.com/spreadsheets/d/${SHEET_ID}/edit?usp=sharing}"
if [[ -z "${CSV_URLS:-}" ]]; then
  CSV_URLS=""
  IFS=',' read -r -a RELEASE_GIDS <<< "${SHEET_GIDS}"
  for RELEASE_GID in "${RELEASE_GIDS[@]}"; do
    CSV_URLS+="${CSV_URLS:+,}https://docs.google.com/spreadsheets/d/${SHEET_ID}/export?format=csv&gid=${RELEASE_GID}"
  done
fi
: "${DISCORD_URL:=https://discord.gg/4GQgGnXN5}"
: "${PROGRAM_URL:=https://drive.google.com/file/d/1sx46MEfKEBswAv_wDgk3Ly1c6PX-ECIB/view?usp=sharing}"
: "${EVENT_THURSDAY:=2026-07-02}"
: "${SUPABASE_URL=https://yfjnurscnzjvjvhrpgwb.supabase.co}"
: "${SHEETS_API_KEY:=}"
: "${SUPABASE_PUBLISHABLE_KEY:=}"
: "${ASC_KEY_ID:=}"
: "${ASC_ISSUER_ID:=}"
: "${ASC_PRIVATE_KEY_PATH:=${HOME}/.appstoreconnect/private_keys/AuthKey_${ASC_KEY_ID}.p8}"
: "${POC_PLAY_JSON_KEY:=${HOME}/.playconsole/playoncon-publisher.json}"
: "${POC_BUNDLE_ID:=com.fuller.playoncon}"
: "${POC_PACKAGE_NAME:=com.fuller.playoncon}"

export SHEET_ID SHEET_GIDS EVENT_THURSDAY SHEETS_API_KEY
export ASC_KEY_ID ASC_ISSUER_ID ASC_PRIVATE_KEY_PATH POC_PLAY_JSON_KEY
export POC_BUNDLE_ID POC_PACKAGE_NAME

release_require_config() {
  [[ -n "${SHEETS_API_KEY}" ]] || { echo 'ERROR: SHEETS_API_KEY is missing; set it in scripts/.env.local.' >&2; return 1; }
  [[ "${SHEET_GIDS}" =~ ^[0-9]+(,[0-9]+)*$ ]] || { echo 'ERROR: SHEET_GIDS must contain comma-separated numeric gids.' >&2; return 1; }
  [[ -n "${SHEET_ID}" && "${EVENT_THURSDAY}" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || { echo 'ERROR: Sheet ID or convention Thursday is invalid.' >&2; return 1; }
  # Both empty explicitly disables the optional live cart layer.
  if [[ -n "${SUPABASE_URL}" && -z "${SUPABASE_PUBLISHABLE_KEY}" ]] || [[ -z "${SUPABASE_URL}" && -n "${SUPABASE_PUBLISHABLE_KEY}" ]]; then
    echo 'ERROR: Set both Supabase values, or explicitly clear both to disable carts.' >&2
    return 1
  fi
}

release_dart_defines() {
  APP_VERSION="$(awk '/^version: / { print $2; exit }' "${RELEASE_PROJECT_ROOT}/pubspec.yaml")"
  [[ "${APP_VERSION}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\+[0-9]+$ ]] || { echo 'ERROR: pubspec.yaml has no valid release version.' >&2; return 1; }
  POC_DART_DEFINES=(
    "--dart-define=POC_SHEETS_API_KEY=${SHEETS_API_KEY}"
    "--dart-define=POC_SHEET_ID=${SHEET_ID}"
    "--dart-define=POC_SHEET_GIDS=${SHEET_GIDS}"
    "--dart-define=POC_SCHEDULE_CSV_URL=${CSV_URLS}"
    "--dart-define=POC_SCHEDULE_VIEW_URL=${SHEET_VIEW_URL}"
    "--dart-define=POC_DISCORD_INVITE_URL=${DISCORD_URL}"
    "--dart-define=POC_PROGRAM_URL=${PROGRAM_URL}"
    "--dart-define=POC_EVENT_THURSDAY=${EVENT_THURSDAY}"
    "--dart-define=POC_SUPABASE_URL=${SUPABASE_URL}"
    "--dart-define=POC_SUPABASE_PUBLISHABLE_KEY=${SUPABASE_PUBLISHABLE_KEY}"
    "--dart-define=POC_APP_VERSION=${APP_VERSION}"
  )
}
