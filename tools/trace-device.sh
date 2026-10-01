#!/usr/bin/env bash
# Record the existing device app; never install, launch, or reset it.
set -euo pipefail
cd "$(dirname "$0")/.."
export GIT_CONFIG_PARAMETERS="${GIT_CONFIG_PARAMETERS-'safe.bareRepository=all'}"
exec tools/with-apple-build-lease.sh plozz/device-capture -- python3 tools/trace-device.py "$@"
