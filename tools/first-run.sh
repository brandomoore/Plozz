#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
exec tools/with-apple-build-lease.sh plozz/first-run -- python3 tools/first-run.py "$@"
