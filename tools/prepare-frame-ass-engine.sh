#!/bin/bash
# Prepare the local-only tvOS integration without modifying SwiftPM checkouts.
set -euo pipefail
cd "$(dirname "$0")/.."
export GIT_CONFIG_PARAMETERS="'safe.bareRepository=all'"
dest=.build/normal-ass/AetherEngine
patch="$PWD/Vendor/Patches/aether-frame-ass.patch"
pin=5d8bd5bddf09c7bfe4155dc62bb04ece62b63c03
verify() {
    local extra
    extra="$(git -C "$dest" ls-files --others --exclude-standard -- Sources Package.swift Plugins)" || return 1
    [[ "$(git -C "$dest" rev-parse HEAD)" == "$pin" ]] &&
        git -C "$dest" diff --binary HEAD | cmp -s - "$patch" &&
        [[ -z "$extra" ]]
}
if [[ "${1:-}" == --verify-only && ! -f "$dest/.plozz-frame-ass" ]]; then exit 0; fi
test "$(python3 -c 'import json; print(next(p["state"]["revision"] for p in json.load(open("Package.resolved"))["pins"] if p["identity"]=="aetherengine"))')" = "$pin" || { echo "error: The frame ASS patch requires a different AetherEngine pin." >&2; exit 1; }
if [[ "${1:-}" == --verify-only ]]; then
    verify || { echo "error: Prepared AetherEngine differs from Package.resolved or the frame ASS patch. Preserve local edits and prepare a matching checkout before building." >&2; exit 1; }
    exit 0
fi
source tools/lib/apple-build-lease.sh
acquire_apple_build_shared_lease plozz/prepare-frame-ass
trap release_apple_build_lease EXIT
if [[ ! -e "$dest" ]]; then
    mkdir -p "$(dirname "$dest")"
    git clone --no-checkout "${1:-https://github.com/brandomoore/AetherEngine}" "$dest"
    git -C "$dest" checkout --detach "$pin"
    git -C "$dest" apply --index "$patch"
fi
# Refuse a stale or edited checkout rather than overwriting anyone's changes.
verify || { echo "error: Prepared AetherEngine does not match the pinned source and patch." >&2; exit 1; }
touch "$dest/.plozz-frame-ass"
echo "Prepared $dest at $pin with the frame ASS patch."
