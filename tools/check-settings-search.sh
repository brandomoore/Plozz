#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

source tools/lib/apple-build-lease.sh
acquire_apple_build_shared_lease "plozz/settings-search-coverage"
install_apple_build_lease_traps

build="$PWD/.build/settings-search-guard"
mkdir -p "$build"
compiler="$(xcrun --find swiftc)"
host_libs="$(dirname "$compiler")/../lib/swift/host"
signature="$( { shasum -a 256 tools/settings-search-inventory.swift; "$compiler" --version; printf '%s\n' "$compiler"; } | shasum -a 256)"
if [[ ! -x "$build/inventory" || ! -f "$build/compiler-signature" || "$(cat "$build/compiler-signature")" != "$signature" ]]; then
    python3 tools/run-bounded.py 120 "Settings source inventory compiler" -- \
        xcrun swiftc -swift-version 5 -module-cache-path "$build/module-cache" \
        -I "$host_libs" -L "$host_libs" \
        -lSwiftSyntax -lSwiftParser -lSwiftParserDiagnostics -lSwiftDiagnostics \
        -Xlinker -rpath -Xlinker "$host_libs" \
        tools/settings-search-inventory.swift -o "$build/inventory"
    printf '%s\n' "$signature" > "$build/compiler-signature"
fi

PLOZZ_SETTINGS_SEARCH_INVENTORY="$build/inventory" \
    python3 -m unittest discover -s tools/tests -p 'test_settings_search_guard.py'
python3 tools/run-bounded.py 120 "Settings source inventory" -- \
    "$build/inventory" "$PWD" tools/settings-search-coverage.json > "$build/inventory.json"
python3 tools/settings-search-guard.py \
    --inventory "$build/inventory.json" --policy tools/settings-search-coverage.json
