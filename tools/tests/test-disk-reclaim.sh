#!/usr/bin/env bash
# Legacy broad-deletion scenarios are replaced by exact-manifest fixtures.
set -euo pipefail
cd "$(dirname "$0")/../.."
export PYTHONDONTWRITEBYTECODE=1
exec /usr/bin/python3 -m unittest \
  tools.tests.test_apple_build_cleanup tools.tests.test_plozz_build_lifecycle
