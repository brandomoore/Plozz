#!/usr/bin/env bash

# Configure Xcode's SwiftPM storage without sharing mutable checkout state
# between independent writers. The compressed repository/artifact cache is safe
# to reuse; checkouts and artifact extraction remain private to the caller.
configure_plozz_package_resolution() {
  if [[ "$#" -lt 1 || "$#" -gt 2 || -z "$1" ]]; then
    echo "configure_plozz_package_resolution: expected private packages and optional DerivedData" >&2
    return 2
  fi

  local cloned_source_packages="$1"
  local package_cache="${PLOZZ_PACKAGE_CACHE_PATH:-$HOME/Library/Caches/org.swift.swiftpm}"
  local lifecycle_args=()
  if [[ "$#" -eq 2 ]]; then
    lifecycle_args+=(--root derived-data "$2")
  fi
  lifecycle_args+=(--root package-workspace "$cloned_source_packages")
  local lifecycle_tool
  lifecycle_tool="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/plozz-build-lifecycle.py"
  /usr/bin/python3 -B "$lifecycle_tool" register --repo "$PWD" \
    "${lifecycle_args[@]}" >/dev/null || return $?
  PACKAGE_RESOLUTION_ARGS=(
    -clonedSourcePackagesDirPath "$cloned_source_packages"
    -packageCachePath "$package_cache"
    -onlyUsePackageVersionsFromResolvedFile
    -skipPackageUpdates
  )
  # `xcodebuild -list` also uses PACKAGE_RESOLUTION_ARGS and rejects a
  # DerivedData override without a scheme. Keep build-location flags separate.
  BUILD_LOCATION_ARGS=()
  if [[ "$#" -eq 2 ]]; then BUILD_LOCATION_ARGS=(-derivedDataPath "$2"); fi
}
