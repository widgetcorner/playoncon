#!/usr/bin/env bash
# Native Apple captures. Select the simulator/Duo display pose before capture;
# this script never folds, unfolds, creates, boots, or deletes simulators.
set -euo pipefail
APPLE_CAPTURE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APPLE_CAPTURE_APP="${POC_CAPTURE_APP_PATH:-${APPLE_CAPTURE_ROOT}/build/ios/iphonesimulator/Runner.app}"
APPLE_CAPTURE_BUNDLE="${POC_CAPTURE_BUNDLE_ID:-com.fuller.playoncon}"
cd "${APPLE_CAPTURE_ROOT}"

apple_capture_prepare() {
  python3 - "${APPLE_CAPTURE_ROOT}" <<'PY'
import json, re, sys
from pathlib import Path
root = Path(sys.argv[1])
target = root / 'tool/apple_capture_main.dart'
fixtures = [
    ('_captureScheduleJson', 'screenshot-schedule.json'),
    ('_captureScenarioJson', 'screenshot-scenario.json'),
    ('_captureConfigJson', 'screenshot-config.json'),
]
declarations = []
for name, filename in fixtures:
    value = (root / 'test/fixtures' / filename).read_text()
    json.loads(value)
    # JSON's double-quoted string escaping matches Dart; escape interpolation.
    literal = json.dumps(value, ensure_ascii=False).replace('$', r'\$')
    declarations.append(f'const {name} = {literal};')
region = '// BEGIN FROZEN CAPTURE DATA\n'
region += '// Generated from the deliberate screenshot fixtures by the build wrapper.\n'
region += '\n'.join(declarations) + '\n// END FROZEN CAPTURE DATA'
source = target.read_text()
source, count = re.subn(
    r'// BEGIN FROZEN CAPTURE DATA\n.*?// END FROZEN CAPTURE DATA',
    lambda _: region, source, flags=re.S,
)
if count != 1:
    raise SystemExit('Capture entry point has no unique fixture region.')
target.write_text(source)
print('Embedded frozen schedule, scenario, and public configuration in the capture entry point.')
PY
}

apple_capture_usage() {
  cat <<'HELP'
Usage:
  scripts/capture-apple-store-assets.sh prepare
  scripts/capture-apple-store-assets.sh build [extra Flutter build flags]
  scripts/capture-apple-store-assets.sh install <simulator-UDID>
  scripts/capture-apple-store-assets.sh capture <simulator-UDID> <output-directory> [light|dark]

Build once, then install that same app on each desired native Apple simulator.
Set the iPhone Duo outer/inner display pose in Device Hub before capture.
Set POC_CAPTURE_DISPLAY=1 for the Duo outer display or =3 for the inner display.
Other simulators use the primary display by default. Capture records five
full-resolution, opaque RGB PNGs, including native status bars and safe areas.
Each image must match the app's ready viewport and contain visible content.
Raw PNGs and request/ready records stay in a private temporary directory. Appearance comes
from the simulator OS; the app keeps the real native Apple/Duo layout stream.

The wrapper writes Documents/poc_capture_request.json in the app's data container
before each launch: {"screen":"my-schedule","nonce":"<unique-request-id>"}.
The app reads that request at startup and echoes its nonce in the ready marker.
Screens: all-sessions, my-schedule, event-detail, venue-map, info.
With no request file, the first screen is All Sessions. A compile-time
POC_CAPTURE_SCREEN define is also supported for manual diagnosis.
If a route fails, inspect the simulator's unified log for POC_CAPTURE or Runner.
HELP
}

case "${1:-help}" in
  prepare)
    apple_capture_prepare
    ;;
  build)
    shift
    apple_capture_prepare
    flutter build ios --simulator --debug --no-pub \
      --target tool/apple_capture_main.dart \
      --dart-define-from-file=test/fixtures/screenshot-config.json "$@"
    printf 'Native capture app: %s\n' "${APPLE_CAPTURE_APP}"
    ;;
  install)
    [[ $# -eq 2 ]] || { apple_capture_usage >&2; exit 2; }
    [[ -d "${APPLE_CAPTURE_APP}" ]] || { echo 'Build the simulator capture app first.' >&2; exit 1; }
    xcrun simctl install "$2" "${APPLE_CAPTURE_APP}"
    ;;
  capture)
    [[ $# -ge 3 && $# -le 4 ]] || { apple_capture_usage >&2; exit 2; }
    APPLE_CAPTURE_DEVICE="$2"
    APPLE_CAPTURE_OUTPUT="$3"
    APPLE_CAPTURE_APPEARANCE="${4:-light}"
    APPLE_CAPTURE_DISPLAY="${POC_CAPTURE_DISPLAY:-}"
    APPLE_CAPTURE_SCREENSHOT_ARGS=(--mask=ignored)
    if [[ -n "${APPLE_CAPTURE_DISPLAY}" ]]; then
      APPLE_CAPTURE_SCREENSHOT_ARGS+=("--display=${APPLE_CAPTURE_DISPLAY}")
    fi
    [[ "${APPLE_CAPTURE_APPEARANCE}" == light || "${APPLE_CAPTURE_APPEARANCE}" == dark ]] || {
      echo 'Appearance must be light or dark.' >&2; exit 2;
    }
    mkdir -p "${APPLE_CAPTURE_OUTPUT}"
    APPLE_CAPTURE_LOG_DIR="$(mktemp -d "${TMPDIR:-/tmp}/poc-apple-capture.XXXXXX")"
    xcrun simctl ui "${APPLE_CAPTURE_DEVICE}" appearance "${APPLE_CAPTURE_APPEARANCE}"
    xcrun simctl status_bar "${APPLE_CAPTURE_DEVICE}" override \
      --time '9:41' --batteryState charged --batteryLevel 100
    APPLE_CAPTURE_CONTAINER="$(xcrun simctl get_app_container "${APPLE_CAPTURE_DEVICE}" "${APPLE_CAPTURE_BUNDLE}" data)"
    APPLE_CAPTURE_REQUEST="${APPLE_CAPTURE_CONTAINER}/Documents/poc_capture_request.json"
    APPLE_CAPTURE_MARKER="${APPLE_CAPTURE_CONTAINER}/Documents/poc_capture_ready.json"
    APPLE_CAPTURE_INDEX=0
    for APPLE_CAPTURE_SCREEN in all-sessions my-schedule event-detail venue-map info; do
      APPLE_CAPTURE_INDEX=$((APPLE_CAPTURE_INDEX + 1))
      APPLE_CAPTURE_NONCE="$(date +%s)-$$-${APPLE_CAPTURE_SCREEN}"
      python3 - "${APPLE_CAPTURE_REQUEST}" "${APPLE_CAPTURE_NONCE}" "${APPLE_CAPTURE_SCREEN}" <<'PY'
import json, sys
from pathlib import Path
request = Path(sys.argv[1])
request.parent.mkdir(parents=True, exist_ok=True)
temporary = request.with_suffix('.tmp')
temporary.write_text(json.dumps({'nonce': sys.argv[2], 'screen': sys.argv[3]}))
temporary.replace(request)
PY
      cp "${APPLE_CAPTURE_REQUEST}" "${APPLE_CAPTURE_LOG_DIR}/${APPLE_CAPTURE_SCREEN}.request.json"
      xcrun simctl launch --terminate-running-process \
        "${APPLE_CAPTURE_DEVICE}" "${APPLE_CAPTURE_BUNDLE}"
      APPLE_CAPTURE_READY=false
      for APPLE_CAPTURE_ATTEMPT in {1..80}; do
        if python3 - "${APPLE_CAPTURE_MARKER}" "${APPLE_CAPTURE_NONCE}" "${APPLE_CAPTURE_SCREEN}" "${APPLE_CAPTURE_APPEARANCE}" <<'PY'
import json, sys
from pathlib import Path
try:
    marker = json.loads(Path(sys.argv[1]).read_text())
    ready = (
        marker.get('nonce') == sys.argv[2]
        and marker.get('screen') == sys.argv[3]
        and marker.get('brightness') == sys.argv[4]
        and marker.get('fixture_events') == 103
        and marker.get('width', 0) > 0
        and marker.get('height', 0) > 0
    )
except (OSError, ValueError):
    ready = False
sys.exit(0 if ready else 1)
PY
        then
          APPLE_CAPTURE_READY=true
          break
        fi
        sleep 0.25
      done
      if [[ "${APPLE_CAPTURE_READY}" != true ]]; then
        printf 'Capture route did not become ready: %s. Request records: %s\n' \
          "${APPLE_CAPTURE_SCREEN}" "${APPLE_CAPTURE_LOG_DIR}" >&2
        printf 'Inspect the unified simulator log for POC_CAPTURE or Runner on device %s.\n' \
          "${APPLE_CAPTURE_DEVICE}" >&2
        exit 1
      fi
      APPLE_CAPTURE_PREFIX="$(printf '%02d' "${APPLE_CAPTURE_INDEX}")-${APPLE_CAPTURE_SCREEN}"
      cp "${APPLE_CAPTURE_MARKER}" "${APPLE_CAPTURE_LOG_DIR}/${APPLE_CAPTURE_PREFIX}.ready.json"
      xcrun simctl io "${APPLE_CAPTURE_DEVICE}" screenshot --type=png \
        "${APPLE_CAPTURE_SCREENSHOT_ARGS[@]}" \
        "${APPLE_CAPTURE_LOG_DIR}/${APPLE_CAPTURE_PREFIX}.raw.png"
      python3 "${APPLE_CAPTURE_ROOT}/scripts/opaque_apple_png.py" \
        "${APPLE_CAPTURE_LOG_DIR}/${APPLE_CAPTURE_PREFIX}.raw.png" \
        "${APPLE_CAPTURE_OUTPUT}/${APPLE_CAPTURE_PREFIX}.png" \
        "${APPLE_CAPTURE_LOG_DIR}/${APPLE_CAPTURE_PREFIX}.ready.json"
      cp "${APPLE_CAPTURE_LOG_DIR}/${APPLE_CAPTURE_PREFIX}.ready.json" \
        "${APPLE_CAPTURE_OUTPUT}/${APPLE_CAPTURE_PREFIX}.json"
    done
    printf 'Five native %s screenshots captured in %s\n' \
      "${APPLE_CAPTURE_APPEARANCE}" "${APPLE_CAPTURE_OUTPUT}"
    printf 'Raw screenshots and request/ready records: %s\n' "${APPLE_CAPTURE_LOG_DIR}"
    ;;
  help|-h|--help)
    apple_capture_usage
    ;;
  *)
    apple_capture_usage >&2
    exit 2
    ;;
esac
