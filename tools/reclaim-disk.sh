#!/usr/bin/env bash
# Compatibility entrypoint: broad build-cache apply has been retired.
set -euo pipefail
case "${1:-}" in
  --dry-run)
    if [[ "$#" -ne 1 ]]; then
      echo "Broad selection flags are retired; use exact lifecycle proposals." >&2
      exit 75
    fi
    exec /usr/bin/python3 -B "$(dirname "$0")/plozz-build-lifecycle.py" legacy
    ;;
  -h|--help)
    echo "usage: tools/reclaim-disk.sh --dry-run"
    echo "Read-only legacy DerivedData attribution. Apply is permanently retired."
    ;;
  *)
    echo "Legacy broad apply is retired; use tools/plozz-build-lifecycle.py and exact manifests." >&2
    exit 75
    ;;
esac
