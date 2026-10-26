#!/usr/bin/env bash
# Simulator-only unbound runner. Never builds, installs, launches or terminates Plozz.
set -euo pipefail
cd "$(dirname "$0")/.."
umask 077

MODE="${1:-}"
PLATFORM="${2:-}"
if [[ "$PLATFORM" != tvOS && "$PLATFORM" != iOS ]] ||
   [[ "$MODE" != --build-only && "$MODE" != --run ]] ||
   [[ "$MODE" == --build-only && $# != 2 ]] ||
   [[ "$MODE" == --run && $# != 4 ]]; then
    echo "Usage: $0 --build-only tvOS|iOS" >&2
    echo "       $0 --run tvOS|iOS OWNED_BOOTED_SIMULATOR_UUID EXPECTED_APP_EXECUTABLE_SHA256" >&2
    exit 2
fi

SCHEME=PlozzTrackerConnectionTests
if [[ "$PLATFORM" == iOS ]]; then SCHEME=PlozziOSTrackerConnectionTests; fi
DERIVED="$PWD/.build/tracker-connection-$PLATFORM-derived-data"
export GIT_CONFIG_PARAMETERS="'safe.bareRepository=all'"
source tools/lib/apple-build-lease.sh
acquire_apple_build_shared_lease plozz/tracker-connection-tests
install_apple_build_lease_traps
mkdir -p "$PWD/.build"
RUN="$(mktemp -d "$PWD/.build/tracker-connection.XXXXXX")"
echo "Private evidence: $RUN"
git rev-parse HEAD > "$RUN/source-commit.txt"
git diff --binary HEAD -- project.yml Tests/TrackerAcceptanceUITests tools/run-tracker-connection-tests.sh \
    tools/tracker-connection-evidence.py > "$RUN/source.diff"
mkdir -p "$RUN/source/Tests/TrackerAcceptanceUITests" "$RUN/source/tools/tests"
cp project.yml "$RUN/source/"
cp Tests/TrackerAcceptanceUITests/*.swift "$RUN/source/Tests/TrackerAcceptanceUITests/"
cp tools/run-tracker-connection-tests.sh tools/tracker-connection-evidence.py "$RUN/source/tools/"
cp tools/tests/test_tracker_connection_evidence.py "$RUN/source/tools/tests/"

source_hash() {
    python3 - "$1" <<'PY'
import hashlib
from pathlib import Path
import sys
root = Path(sys.argv[1])
paths = [Path("project.yml"), *sorted(path.relative_to(root) for path in
         (root / "Tests/TrackerAcceptanceUITests").glob("*.swift"))]
digest = hashlib.sha256()
for path in paths:
    digest.update(str(path).encode() + b"\0" + (root / path).read_bytes() + b"\0")
print(digest.hexdigest())
PY
}
SOURCE_SHA256="$(source_hash "$RUN/source")"

if [[ "$MODE" == --build-only ]]; then
    source tools/lib/swift-package-storage.sh
    configure_plozz_package_resolution "$PWD/.build/package-workspaces/tracker-connection-tests"
    tools/generate-project.sh > "$RUN/generate.log" 2>&1
    python3 tools/run-bounded.py 900 "unbound tracker runner build" -- \
        xcodebuild build-for-testing -project Plozz.xcodeproj -scheme "$SCHEME" \
        -configuration Debug -destination "generic/platform=$PLATFORM Simulator" \
        -derivedDataPath "$DERIVED" -parallel-testing-enabled NO \
        "${PACKAGE_RESOLUTION_ARGS[@]}" CODE_SIGNING_ALLOWED=NO \
        -resultBundlePath "$RUN/Build.xcresult" > "$RUN/build.log" 2>&1
fi

MANIFEST="$(python3 - "$DERIVED/Build/Products" "$SCHEME" <<'PY'
from pathlib import Path
import sys
paths = list(Path(sys.argv[1]).glob(sys.argv[2] + "_*.xctestrun"))
if len(paths) != 1:
    raise SystemExit("Exactly one built manifest is required; build the dedicated unbound scheme first.")
print(paths[0])
PY
)"
python3 tools/tracker-connection-evidence.py manifest "$MANIFEST" "$PLATFORM" > "$RUN/runner.json"
cp "$MANIFEST" "$RUN/runner.xctestrun"
if [[ "$(source_hash "$PWD")" != "$SOURCE_SHA256" ]]; then
    echo "Runner source changed during this invocation; no build or live pass recorded." >&2
    exit 1
fi
if [[ "$MODE" == --build-only ]]; then
    printf '%s\n' "$SOURCE_SHA256" > "$DERIVED/connection-source.sha256"
    echo "Unbound $PLATFORM connection runner built; no live app test has run."
    exit 0
fi

SIMULATOR="$3"
EXPECTED_APP_SHA256="$4"
python3 - "$SIMULATOR" "$EXPECTED_APP_SHA256" "$DERIVED/connection-source.sha256" "$SOURCE_SHA256" <<'PY'
from pathlib import Path
import re
import sys
import uuid
if str(uuid.UUID(sys.argv[1])).upper() != sys.argv[1] or not re.fullmatch(r"[0-9a-f]{64}", sys.argv[2]):
    raise SystemExit("An exact owned simulator UUID and expected executable hash are required.")
if Path(sys.argv[3]).read_text().strip() != sys.argv[4]:
    raise SystemExit("Runner source changed; rebuild before running.")
PY
python3 tools/run-bounded.py 20 "owned simulator state" -- xcrun simctl list devices --json |
    python3 -c '
import json,sys
data=json.load(sys.stdin)
matches=[(runtime, d) for runtime,devices in data["devices"].items() for d in devices if d["udid"]==sys.argv[1]]
if len(matches)!=1 or matches[0][1]["state"]!="Booted" or (".SimRuntime."+sys.argv[2]+"-") not in matches[0][0]:
    raise SystemExit("The exact selected simulator must already be booted on the requested platform.")
' "$SIMULATOR" "$PLATFORM"
python3 tools/run-bounded.py 20 "installed production application identity" -- \
    xcrun simctl get_app_container "$SIMULATOR" com.thatcube.Plozz app |
    python3 tools/tracker-connection-evidence.py app "$EXPECTED_APP_SHA256" > "$RUN/application.json"

export TEST_RUNNER_PLOZZ_TRACKER_CONNECTION_LIVE=1
export TEST_RUNNER_PLOZZ_TRACKER_CONNECTION_SIMULATOR="$SIMULATOR"
status=0
python3 tools/run-bounded.py 300 "live production-app connection check" -- \
    xcodebuild test-without-building -xctestrun "$MANIFEST" \
    -destination "platform=$PLATFORM Simulator,id=$SIMULATOR" -destination-timeout 20 \
    -parallel-testing-enabled NO -maximum-concurrent-test-simulator-destinations 1 \
    -only-testing:"$SCHEME/PublicMetaDBLiveConnectionTests/testLivePairingCancellationAndInvalidKey" \
    -collect-test-diagnostics never -resultBundlePath "$RUN/Test.xcresult" > "$RUN/test.log" 2>&1 || status=$?
python3 tools/run-bounded.py 30 "connection result summary" -- \
    xcrun xcresulttool get test-results summary --path "$RUN/Test.xcresult" > "$RUN/summary.json"
python3 tools/run-bounded.py 30 "connection result tree" -- \
    xcrun xcresulttool get test-results tests --path "$RUN/Test.xcresult" > "$RUN/tests.json"
if [[ "$status" != 0 ]]; then
    echo "Live runner failed ($status); retained results are not a pass." >&2
    exit "$status"
fi
python3 tools/tracker-connection-evidence.py verdict "$RUN/summary.json" "$RUN/tests.json" "$PLATFORM"
