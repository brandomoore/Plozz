#!/usr/bin/env bash
# Hero-off warm rows driver. Build/install only the unbound XCTest runner, never Plozz.
# Parent confirms current Home with a real card focused; no relaunch or setting changes.
set -euo pipefail
cd "$(dirname "$0")/.."

DEVICE="${PLOZZ_HOME_DEVICE_ID:-${PLOZZ_HOME_ROWS_FIRST:-}}"
APP_ID="${PLOZZ_HOME_APP_BUNDLE_ID:-com.thatcube.Plozz}"
EXPECT_HITCHES="${PLOZZ_HOME_EXPECT_HITCHES:-0}"
if [[ "$EXPECT_HITCHES" != "0" && "$EXPECT_HITCHES" != "1" ]]; then
  echo "PLOZZ_HOME_EXPECT_HITCHES must be 0 or 1." >&2
  exit 2
fi
case "$APP_ID" in
  com.thatcube.Plozz|com.thatcube.Plozz.FocusHost) ;;
  *) echo "Only Plozz and its isolated Home fixture are supported." >&2; exit 2 ;;
esac
if [[ -z "$DEVICE" ]]; then
  echo "Set PLOZZ_HOME_DEVICE_ID to the intended physical Apple TV identifier." >&2
  exit 2
fi
MODE="${1:-}"
REPEATS="${PLOZZ_HOME_REPEATS:-1}"
if [[ ! "$REPEATS" =~ ^[1-3]$ ]]; then
  echo "PLOZZ_HOME_REPEATS must be 1, 2, or 3." >&2
  exit 2
fi
if [[ $# -ne 1 || ( "$MODE" != "--build-runner" && "$MODE" != "--run" && "$MODE" != "--run-hero-off" && "$MODE" != "--run-vertical-only" && "$MODE" != "--run-horizontal-only" && "$MODE" != "--sweep-down" && "$MODE" != "--sweep-up" && "$MODE" != "--measure-right" && "$MODE" != "--measure-left" && "$MODE" != "--measure-down" && "$MODE" != "--measure-up" ) ]]; then
  echo "Usage: bash tools/run-physical-home-rows-first.sh --build-runner"
  echo "Then: PLOZZ_HOME_ROWS_FIRST=$DEVICE PLOZZ_HOME_RELEASE_APP_INSTALLED=1 bash tools/run-physical-home-rows-first.sh --run-hero-off"
  echo "--run is also a hero-off alias."
  echo "Use --run-vertical-only for two vertical steps and their reverse, with no horizontal input."
  echo "Use --run-horizontal-only for a Right/Left hold pair on the focused real row."
  echo "Use --sweep-down or --sweep-up to page through up to four rows per repetition."
  echo "Use --measure-right/left for paging or --measure-down/up for native row-transition hitch metrics."
  exit 2
fi
if [[ "$MODE" != "--build-runner" && ( "${PLOZZ_HOME_ROWS_FIRST:-}" != "$DEVICE" || "${PLOZZ_HOME_RELEASE_APP_INSTALLED:-}" != "1" ) ]]; then
  echo "Requires exact physical-device opt-in and parent-confirmed running Release app." >&2
  exit 2
fi

source tools/lib/apple-build-lease.sh
acquire_apple_build_lease shared physical-home-rows-first
install_apple_build_lease_traps
export GIT_CONFIG_PARAMETERS="'safe.bareRepository=all'"
source tools/lib/swift-package-storage.sh
configure_plozz_package_resolution "$PWD/.build/package-workspaces/physical-home-paging"

DERIVED_DATA="$PWD/build/physical-home-paging-release-derived"
OUT="$PWD/build/physical-home-rows-first/$(date -u +%Y%m%dT%H%M%SZ)-${MODE#--}-$$"
mkdir -p "$OUT"
COMMON=(
  -project Plozz.xcodeproj -scheme PlozzPhysicalHomeRowsTests -configuration Release
  -destination "platform=tvOS,id=$DEVICE" -destination-timeout 30
  -derivedDataPath "$DERIVED_DATA" -parallel-testing-enabled NO
  "${PACKAGE_RESOLUTION_ARGS[@]}" DEVELOPMENT_TEAM=N8Z5T4AK3X
)
echo "Artifacts: $OUT"

if [[ "$MODE" == "--build-runner" ]]; then
  if [[ ! -f Plozz.xcodeproj/xcshareddata/xcschemes/PlozzPhysicalHomeRowsTests.xcscheme ]]; then
    tools/generate-project.sh
  fi
  python3 tools/run-bounded.py 900 "warm rows XCTest runner build" -- \
    xcodebuild build-for-testing "${COMMON[@]}" -allowProvisioningUpdates \
    2>&1 | tee "$OUT/runner-build.log"
  exit 0
fi

# Refuse AUT-bound metadata: XCTest installation must not replace the warm app.
RUN_FILE="$(python3 - "$DERIVED_DATA/Build/Products" "$OUT/runner-metadata.json" <<'PY'
import json
import plistlib
import sys
from pathlib import Path

files = sorted(Path(sys.argv[1]).glob("PlozzPhysicalHomeRowsTests_*.xctestrun"))
if len(files) != 1:
    raise SystemExit("Build the unbound PlozzPhysicalHomeRowsTests scheme first.")
data = plistlib.loads(files[0].read_bytes())
targets = [t for c in data.get("TestConfigurations", []) for t in c.get("TestTargets", [])]
if not targets:
    targets = [v for k, v in data.items() if not k.startswith("__") and isinstance(v, dict)]
target = next((t for t in targets if t.get("BlueprintName") == "PlozzHomeRemoteTests"), None)
if target is None or target.get("UITargetAppPath") or target.get("UITargetAppBundleIdentifier"):
    raise SystemExit("Refusing AUT-bound runner: existing warm Plozz must not be installed/relaunched.")
if any(path.endswith("/Plozz.app") for path in target.get("DependentProductPaths", [])):
    raise SystemExit("Unexpected Plozz app dependency; refusing warm run.")
if target.get("PreferredScreenCaptureFormat") != "screenshots" or target.get("SystemAttachmentLifetime") != "keepNever":
    raise SystemExit("Refusing automatic screen capture during physical performance measurement; rebuild the runner scheme.")
Path(sys.argv[2]).write_text(json.dumps({
    key: target.get(key) for key in (
        "BlueprintName", "TestHostPath", "UITargetAppPath", "DependentProductPaths",
        "PreferredScreenCaptureFormat", "SystemAttachmentLifetime"
    )
}, indent=2) + "\n")
print(files[0])
PY
)"

export TEST_RUNNER_PLOZZ_HOME_ROWS_FIRST="$DEVICE"
export TEST_RUNNER_PLOZZ_HOME_TARGET_DEVICE="$DEVICE"
export TEST_RUNNER_PLOZZ_HOME_APP_CONFIGURATION=Release
export TEST_RUNNER_PLOZZ_HOME_APP_BUNDLE_ID="$APP_ID"
export TEST_RUNNER_PLOZZ_HOME_HERO_OFF=1
export TEST_RUNNER_PLOZZ_HOME_VERTICAL_ONLY=0
export TEST_RUNNER_PLOZZ_HOME_HORIZONTAL_ONLY=0
export TEST_RUNNER_PLOZZ_HOME_SWEEP_DIRECTION=""
export TEST_RUNNER_PLOZZ_HOME_MEASURE_DIRECTION=""
export TEST_RUNNER_PLOZZ_HOME_METRIC_IDLE_CONTROL="${PLOZZ_HOME_METRIC_IDLE_CONTROL:-0}"
if [[ "$TEST_RUNNER_PLOZZ_HOME_METRIC_IDLE_CONTROL" != "0" && "$TEST_RUNNER_PLOZZ_HOME_METRIC_IDLE_CONTROL" != "1" ]]; then
  echo "PLOZZ_HOME_METRIC_IDLE_CONTROL must be 0 or 1." >&2
  exit 2
fi
export TEST_RUNNER_PLOZZ_HOME_SWEEP_STOP_ROW="${PLOZZ_HOME_SWEEP_STOP_ROW:-}"
TEST_METHOD=testHeroDisabledFocusedRowAndAvailableLowerRowsWarm
RUNNER_LIMIT=120
INPUT_BUDGET=100
if [[ "$MODE" == "--run-vertical-only" ]]; then
  export TEST_RUNNER_PLOZZ_HOME_VERTICAL_ONLY=1
  TEST_METHOD=testHeroDisabledVerticalRowsWarm
  RUNNER_LIMIT=60
  INPUT_BUDGET=45
elif [[ "$MODE" == "--run-horizontal-only" ]]; then
  export TEST_RUNNER_PLOZZ_HOME_HORIZONTAL_ONLY=1
  TEST_METHOD=testHeroDisabledHorizontalRowWarm
  RUNNER_LIMIT=60
  INPUT_BUDGET=45
elif [[ "$MODE" == "--sweep-down" || "$MODE" == "--sweep-up" ]]; then
  export TEST_RUNNER_PLOZZ_HOME_SWEEP_DIRECTION="${MODE#--sweep-}"
  TEST_METHOD=testHeroDisabledRowSweepWarm
  RUNNER_LIMIT=150
  INPUT_BUDGET=130
elif [[ "$MODE" == "--measure-right" || "$MODE" == "--measure-left" || "$MODE" == "--measure-down" || "$MODE" == "--measure-up" ]]; then
  export TEST_RUNNER_PLOZZ_HOME_MEASURE_DIRECTION="${MODE#--measure-}"
  TEST_METHOD=testHeroDisabledNativeHitchMetricWarm
  RUNNER_LIMIT=150
  INPUT_BUDGET=130
fi
export TEST_RUNNER_PLOZZ_HOME_CONTINUE_WATCHING_LABEL="${PLOZZ_HOME_CONTINUE_WATCHING_LABEL:-Continue Watching}"
export TEST_RUNNER_PLOZZ_HOME_NAVIGATION_LABEL="${PLOZZ_HOME_NAVIGATION_LABEL:-Home}"
export TEST_RUNNER_PLOZZ_HOME_START_ROW="${PLOZZ_HOME_START_ROW:-}"
printf 'scenario=hero-off\nverticalOnly=%s\nhorizontalOnly=%s\nsweepDirection=%s\nlifecycle=warm-existing-no-relaunch\ncausalComparison=false\nmetricIdleControl=%s\n' \
  "$TEST_RUNNER_PLOZZ_HOME_VERTICAL_ONLY" "$TEST_RUNNER_PLOZZ_HOME_HORIZONTAL_ONLY" \
  "$TEST_RUNNER_PLOZZ_HOME_SWEEP_DIRECTION" "$TEST_RUNNER_PLOZZ_HOME_METRIC_IDLE_CONTROL" > "$OUT/scenario.txt"
printf 'bundleID=%s\nexpectHitches=%s\n' "$APP_ID" "$EXPECT_HITCHES" >> "$OUT/scenario.txt"
if [[ "$EXPECT_HITCHES" == "1" && -z "$TEST_RUNNER_PLOZZ_HOME_MEASURE_DIRECTION" ]]; then
  echo "Positive-control expectations require a native metric workload." >&2
  exit 2
fi
echo "Warm app only: do not launch, terminate, replace, or change its environment."
echo "Keep the user's Home hero OFF. This row-only isolation does not establish hero causation."
echo "Existing diagnostics should already include PLZPERF_STDOUT=1 PLZXMEM=1 PLZPERF_ANIMATIONS=1 PLZIO=1."
echo "Wait for PLZROWS warm-ready; confirm current Home with an actual populated row/card focused, then:"
echo "xcrun devicectl device notification post --device $DEVICE --name <confirmedNotification> --timeout 15"
echo "30s confirmation, 15s real-card readiness, ${INPUT_BUDGET}s input budget, ${RUNNER_LIMIT}s hard runner limit."
if [[ "$MODE" == "--run-vertical-only" ]]; then
  echo "No Left/Right calls or holds: two steps through identifiable real rows, then reverse to the starting row."
  echo "Any currently focused real row is eligible; unavailable lower rows report NOT_READY and partial coverage."
elif [[ "$MODE" == "--run-horizontal-only" ]]; then
  echo "Right/Left holds on the currently focused real row; no vertical coverage is claimed."
elif [[ -n "$TEST_RUNNER_PLOZZ_HOME_SWEEP_DIRECTION" ]]; then
  echo "Sweep: four rows per repetition, with Right/Left holds and verified vertical transitions."
  echo "Starting-row preparation runs only on the first repetition; later repetitions continue from the reached row."
elif [[ -n "$TEST_RUNNER_PLOZZ_HOME_MEASURE_DIRECTION" ]]; then
  echo "Native hitch metric: horizontal holds or one verified vertical step; accessibility checks and reset inputs stay outside measurement."
else
  echo "First input is a Right hold on the currently focused real row, not Down from a hero."
  echo "Coverage: starting-row horizontal paging and at most two available lower rows; inspect named coverage for Continue Watching."
fi

REPEAT_ARGS=()
if [[ "$REPEATS" -gt 1 ]]; then
  REPEAT_ARGS=(-test-iterations "$REPEATS" -test-repetition-relaunch-enabled NO)
fi
if python3 tools/run-bounded.py "$((RUNNER_LIMIT * REPEATS))" "hero-off warm row paging" -- \
  xcodebuild test-without-building -xctestrun "$RUN_FILE" \
  -destination "platform=tvOS,id=$DEVICE" -destination-timeout 30 \
  -parallel-testing-enabled NO \
  "-only-testing:PlozzHomeRemoteTests/PhysicalHomeRowsFirstTests/$TEST_METHOD" \
  "-only-testing:PlozzHomeRemoteTests/PhysicalHomeRowsFirstTests/testRowMatchingDistinguishesSharedLeadingTitles" \
  "${REPEAT_ARGS[@]+"${REPEAT_ARGS[@]}"}" \
  -test-timeouts-enabled YES -default-test-execution-time-allowance "$RUNNER_LIMIT" \
  -maximum-test-execution-time-allowance "$RUNNER_LIMIT" -collect-test-diagnostics never \
  -resultBundlePath "$OUT/RowsFirst.xcresult" 2>&1 | tee "$OUT/test.log"; then
  STATUS=0
else
  STATUS=$?
fi
if ! xcrun devicectl device copy from --device "$DEVICE" \
  --domain-type appDataContainer --domain-identifier "$APP_ID" \
  --source Library/Caches/plzxmem.log --destination "$OUT/plzxmem.log" \
  --timeout 30 --json-output "$OUT/diagnostic-copy.json"; then
  echo "testExit=$STATUS; diagnostic copy failed. Warm app was not relaunched." >&2
  exit 1
fi
if [[ "$STATUS" -ne 0 ]]; then
  echo "Driver failed ($STATUS). Distinguish NOT_READY from INPUT_FAILED in test.log." >&2
  exit "$STATUS"
fi
if [[ -n "$TEST_RUNNER_PLOZZ_HOME_MEASURE_DIRECTION" ]]; then
  xcrun xcresulttool get test-results metrics --path "$OUT/RowsFirst.xcresult" > "$OUT/native-metrics.json"
  python3 - "$OUT/native-metrics.json" "$EXPECT_HITCHES" <<'PY'
import json
import math
from pathlib import Path
import sys

data = json.loads(Path(sys.argv[1]).read_text())
metrics = []
def visit(value):
    if isinstance(value, dict):
        if "hitch" in str(value.get("displayName", "")).lower():
            measurements = value.get("measurements", [])
            if len(measurements) >= 3 and all(isinstance(item, (int, float)) and math.isfinite(item) for item in measurements):
                metrics.append(value)
        for child in value.values():
            visit(child)
    elif isinstance(value, list):
        for child in value:
            visit(child)
visit(data)
if not metrics:
    raise SystemExit("No complete native hitch measurements; functional navigation alone is not a performance result.")
if sys.argv[2] == "1" and not any(
    value > 0 for metric in metrics for value in metric["measurements"]
):
    raise SystemExit("Positive control reported no hitches; verify the measured executable before trusting zero results.")
PY
fi
if ! grep -q 'PLZROWS .* hero-off.row-ready ' "$OUT/test.log" ||
   ! grep -q 'PLZROWS .* complete[[:space:]]*$' "$OUT/test.log"; then
  echo "Missing real hero-off starting-row/completion evidence; skipped tests are not success." >&2
  exit 1
fi
COMPLETIONS="$(grep -c 'PLZROWS .* complete[[:space:]]*$' "$OUT/test.log" || true)"
if [[ "$COMPLETIONS" -ne "$REPEATS" ]]; then
  echo "Expected $REPEATS complete navigation runs; observed $COMPLETIONS." >&2
  exit 1
fi
if [[ "$MODE" != "--run-horizontal-only" && -z "$TEST_RUNNER_PLOZZ_HOME_SWEEP_DIRECTION" && -z "$TEST_RUNNER_PLOZZ_HOME_MEASURE_DIRECTION" ]] &&
   { ! grep -q 'PLZROWS .* lower-row.verified ' "$OUT/test.log" ||
     ! grep -q 'PLZROWS .* hero-off.starting-row.restored[[:space:]]*$' "$OUT/test.log"; }; then
  echo "Missing verified vertical movement and return." >&2
  exit 1
fi
if [[ -n "$TEST_RUNNER_PLOZZ_HOME_MEASURE_DIRECTION" ]]; then
  if ! grep -q 'PLZROWS .* native.metric.verified ' "$OUT/test.log"; then
    echo "Missing verified native hitch workload." >&2
    exit 1
  fi
elif [[ -n "$TEST_RUNNER_PLOZZ_HOME_SWEEP_DIRECTION" ]]; then
  if ! grep -q 'PLZROWS .* sweep.row.verified ' "$OUT/test.log" ||
     ! grep -q 'PLZROWS .* sweep.coverage ' "$OUT/test.log"; then
    echo "Missing actual per-row sweep coverage." >&2
    exit 1
  fi
elif [[ "$MODE" == "--run-vertical-only" ]]; then
  if ! grep -q 'PLZROWS .* vertical-only.start-row.ready ' "$OUT/test.log" ||
     ! grep -q 'PLZROWS .* vertical-only.verified down=2 up=2[[:space:]]*$' "$OUT/test.log"; then
    echo "Missing complete two-Down/two-Up evidence; partial vertical coverage is not a passing run." >&2
    exit 1
  fi
elif ! grep -q 'PLZROWS .* first-row.horizontal.verified ' "$OUT/test.log"; then
  echo "Missing horizontal input evidence." >&2
  exit 1
fi
if ! grep 'PLZPERF .*fps=' "$OUT/plzxmem.log" > "$OUT/frame-samples.log"; then
  echo "No app frame samples; navigation may pass, but performance is unmeasured." >&2
  exit 1
fi
python3 - "$OUT" <<'PY'
import json
from pathlib import Path
import re
import sys

directory = Path(sys.argv[1])
windows = []
pending = {}
for line in (directory / "test.log").read_text().splitlines():
    match = re.match(
        r"PLZROWS .*uptime=([\d.]+).* origin=warm-confirmation "
        r"(first-row|lower-rows)\.input-window\.(begin|end)", line
    )
    if not match:
        continue
    timestamp, name, edge = match.groups()
    if edge == "begin":
        pending[name] = float(timestamp) * 1000
    elif name in pending:
        windows.append((name, pending.pop(name), float(timestamp) * 1000))
if not windows or pending:
    raise SystemExit("Missing complete measured input windows.")
frames = []
for line in (directory / "frame-samples.log").read_text().splitlines():
    match = re.search(r"fps=(\d+).*worst=(\d+)ms.*gapEndUptimeMs=([\d.]+)", line)
    if match:
        fps, worst, end = match.groups()
        frames.append((float(end), int(fps), int(worst)))
summary = []
for name, start, end in windows:
    samples = [sample for sample in frames if start <= sample[0] <= end]
    if not samples:
        raise SystemExit(f"No contemporaneous Home frames for {name}; stale or inactive-display logs cannot qualify.")
    summary.append({
        "name": name, "startUptimeMs": start, "endUptimeMs": end,
        "sampleCount": len(samples),
        "minimumReportedEMAFPS": min(sample[1] for sample in samples),
        "maximumReportedGapMs": max(sample[2] for sample in samples),
    })
(directory / "frame-window-summary.json").write_text(json.dumps({
    "windows": summary,
    "limitations": "Window includes XCTest waits and bracketed AX checks; sampled callback gaps are not presented-frame metrics or a smoothness verdict."
}, indent=2) + "\n")
PY
echo "Warm UI-input coverage recorded. Align frame samples with PLZROWS uptime windows; full app log includes earlier history."
