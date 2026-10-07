#!/usr/bin/env bash
# Keep the old command name diagnostic-only; never infer deletion from absence.
set -euo pipefail
exec "$(dirname "$0")/reclaim-disk.sh" "$@"
