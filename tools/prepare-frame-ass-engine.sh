#!/bin/bash
# Prepare the local-only tvOS integration without modifying SwiftPM checkouts.
set -euo pipefail
cd "$(dirname "$0")/.."
export GIT_CONFIG_PARAMETERS="'safe.bareRepository=all'"
source tools/lib/apple-build-lease.sh
acquire_apple_build_shared_lease plozz/prepare-frame-ass
trap release_apple_build_lease EXIT
pin=754eadcb5f6c6018c9e2ce53fd554777b89c6b50
dest=.build/normal-ass/AetherEngine
patch="$PWD/Vendor/Patches/aether-frame-ass.patch"
test "$(python3 -c 'import json; print(next(p["state"]["revision"] for p in json.load(open("Package.resolved"))["pins"] if p["identity"]=="aetherengine"))')" = "$pin"
if [[ ! -e "$dest" ]]; then
    mkdir -p "$(dirname "$dest")"
    git clone --no-checkout "${1:-https://github.com/brandomoore/AetherEngine}" "$dest"
    git -C "$dest" checkout --detach "$pin"
    git -C "$dest" apply --index "$patch"
fi
# Refuse a stale or edited checkout rather than overwriting anyone's changes.
test "$(git -C "$dest" rev-parse HEAD)" = "$pin"
git -C "$dest" diff --binary HEAD | cmp - "$patch"
touch "$dest/.plozz-frame-ass"
echo "Prepared $dest at $pin with the frame ASS patch."
