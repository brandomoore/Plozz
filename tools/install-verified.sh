#!/usr/bin/env bash
# Shared bounded CoreDevice installer. See --help for retry controls.
set -euo pipefail
exec /usr/bin/python3 "$(dirname "$0")/install-verified.py" "$@"
