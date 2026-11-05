#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
export GIT_CONFIG_PARAMETERS="'safe.bareRepository=all'"
exec tools/with-apple-build-lease.sh plozz/unsigned-ipa -- \
  python3 tools/build-unsigned-ipa.py "$@"
