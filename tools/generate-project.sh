#!/bin/sh
# generate-project.sh — regenerate Plozz.xcodeproj via XcodeGen AND bake an
# auto-incrementing build number into it, so CFBundleVersion lands natively in
# every target's Info.plist at build time. The app and the Top Shelf extension
# share the baked value (lockstep), and because it's a real build setting there's
# no fragile post-build plist editing to race with embedding/codesigning.
#
# ALWAYS generate the project with this script (not a bare `xcodegen generate`)
# so the build number is never missed. The build/deploy flow and fastlane both
# call it.
#
# Build number precedence:
#   1. $PLOZZ_BUILD_NUMBER  — explicit override. The fastlane `build` lane sets
#      this to (latest TestFlight build + 1) so App Store / TestFlight uploads
#      stay strictly increasing per upload even without a new commit.
#   2. git commit count (`git rev-list --count HEAD`) — auto-increments on every
#      commit, so each local/device/simulator build shows a fresh build number in
#      the Settings "About" panel.
# If neither is available, the project.yml default (1) is left in place so the
# build still succeeds.
set -eu

cd "$(dirname "$0")/.."

BAKE_ONLY=0
for arg in "$@"; do
  case "$arg" in
    --bake-only) BAKE_ONLY=1 ;;
    -h|--help)
      echo "usage: tools/generate-project.sh [--bake-only]"
      echo "  --bake-only  update version/build settings in an existing project without running XcodeGen"
      exit 0
      ;;
    *) echo "unknown flag: $arg" >&2; exit 2 ;;
  esac
done

. tools/lib/apple-build-lease.sh
acquire_apple_build_shared_lease "plozz/generate-project"
install_apple_build_lease_traps

# Per-branch bundle-id / display-name suffixes (see project.yml). Default EMPTY so
# a normal run generates the canonical `com.thatcube.Plozz` / "Plozz". An opt-in
# per-branch build (tools/deploy-*.sh --branded) exports these before calling us so
# xcodegen expands ${PLOZZ_ID_SUFFIX}/${PLOZZ_NAME_SUFFIX} into a separate app.
# We MUST export them even when empty — xcodegen leaves an UNSET ${VAR} as the
# literal token, which would break the canonical bundle id.
export PLOZZ_ID_SUFFIX="${PLOZZ_ID_SUFFIX:-}"
export PLOZZ_NAME_SUFFIX="${PLOZZ_NAME_SUFFIX:-}"
export PLOZZ_PAIRING_SERVICE_TYPE="${PLOZZ_PAIRING_SERVICE_TYPE:-_plozz-pair._tcp}"
export PLOZZ_URL_SCHEME="${PLOZZ_URL_SCHEME:-plozz}"
# tvOS entitlements paths — canonical by default. A --branded build overrides
# these with the stripped variants (User Management + App Group removed) so a
# fresh per-branch App ID can sign without those special capabilities.
export PLOZZ_TV_APP_ENTITLEMENTS="${PLOZZ_TV_APP_ENTITLEMENTS:-App/Resources/Plozz.entitlements}"
export PLOZZ_TV_TOPSHELF_ENTITLEMENTS="${PLOZZ_TV_TOPSHELF_ENTITLEMENTS:-TopShelf/TopShelf.entitlements}"
# iOS entitlements path — same story as tvOS above. A --branded build overrides it
# with the stripped variant so a fresh per-branch App ID can sign without the
# canonical app's Push / iCloud / Associated Domains capabilities.
export PLOZZ_IOS_APP_ENTITLEMENTS="${PLOZZ_IOS_APP_ENTITLEMENTS:-App/PlozziOS/PlozziOS.entitlements}"

# Xcode resolves xcconfig includes before scheme pre-actions run, so linking the
# local override from a scheme is one build too late. Restore it here before
# either XcodeGen or the bake-only device-build path reads build settings.
secrets_file="Config/Secrets.local.xcconfig"
canonical_secrets="${XDG_CONFIG_HOME:-$HOME/.config}/plozz/Secrets.local.xcconfig"
if [ ! -e "$secrets_file" ] && [ -f "$canonical_secrets" ]; then
  ln -s "$canonical_secrets" "$secrets_file"
  echo "Linked $secrets_file from $canonical_secrets"
fi

proj_dir="Plozz.xcodeproj"
proj="${proj_dir}/project.pbxproj"
generation_signature_file="${proj_dir}/.plozz-generation-signature"
canonical_package_lock="Package.resolved"
workspace_package_lock="${proj_dir}/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
generation_signature="$(
  {
    shasum -a 256 project.yml Package.swift "$canonical_package_lock"
    printf '%s\n' \
      "PLOZZ_ID_SUFFIX=${PLOZZ_ID_SUFFIX}" \
      "PLOZZ_NAME_SUFFIX=${PLOZZ_NAME_SUFFIX}" \
      "PLOZZ_PAIRING_SERVICE_TYPE=${PLOZZ_PAIRING_SERVICE_TYPE}" \
      "PLOZZ_URL_SCHEME=${PLOZZ_URL_SCHEME}" \
      "PLOZZ_TV_APP_ENTITLEMENTS=${PLOZZ_TV_APP_ENTITLEMENTS}" \
      "PLOZZ_TV_TOPSHELF_ENTITLEMENTS=${PLOZZ_TV_TOPSHELF_ENTITLEMENTS}" \
      "PLOZZ_IOS_APP_ENTITLEMENTS=${PLOZZ_IOS_APP_ENTITLEMENTS}"
    # XcodeGen expands directory sources into concrete file references. Git pulls
    # can change that set while leaving this ignored project behind, so paths are
    # part of the signature even though ordinary source-content edits are not.
    find App Sources Tests TopShelf -type f -print | LC_ALL=C sort
  } | shasum -a 256 | awk '{print $1}'
)"

should_generate=0
if [ "$BAKE_ONLY" != "1" ]; then
  should_generate=1
elif [ ! -f "$proj" ]; then
  echo "error: --bake-only requires an existing Plozz.xcodeproj; run without it once" >&2
  exit 1
elif [ ! -f "$generation_signature_file" ] \
  || [ "$(cat "$generation_signature_file")" != "$generation_signature" ]; then
  echo "Project inputs changed since the last XcodeGen run; regenerating automatically."
  should_generate=1
fi

if [ "$should_generate" = "1" ]; then
  xcodegen generate
  printf '%s\n' "$generation_signature" > "$generation_signature_file"
fi

# Xcode project builds read the workspace lock rather than the package-root lock.
# Keep the generated copy byte-for-byte identical on both full generation and
# bake-only runs so every entrypoint resolves the committed dependency graph.
workspace_package_dir=$(dirname "$workspace_package_lock")
mkdir -p "$workspace_package_dir"
if ! cmp -s "$canonical_package_lock" "$workspace_package_lock"; then
  temporary_package_lock="${workspace_package_lock}.tmp.$$"
  cp "$canonical_package_lock" "$temporary_package_lock"
  mv -f "$temporary_package_lock" "$workspace_package_lock"
  echo "Synced ${canonical_package_lock} to ${workspace_package_lock}"
fi

# If PLOZZ_SENTRY_DSN wasn't provided in the environment, read it from a
# gitignored env file so one file feeds both local device builds and `fastlane`
# (which also exports it). An explicit env override always wins.
#
# The per-worktree .env.fastlane is checked first, then a machine-wide file that
# lives OUTSIDE any checkout. That second location matters: .env.fastlane is
# gitignored, so it does not exist in a freshly created worktree — which is how
# every build since the DSN was first configured silently shipped with crash
# reporting disabled. The machine-wide copy survives worktrees and branches.
PLOZZ_ENV_FILES="${PLOZZ_ENV_FILE:-} .env.fastlane ${XDG_CONFIG_HOME:-$HOME/.config}/plozz/env"
if [ -z "${PLOZZ_SENTRY_DSN:-}" ]; then
  for env_file in $PLOZZ_ENV_FILES; do
    [ -n "$env_file" ] && [ -f "$env_file" ] || continue
    dsn_line=$(grep -E '^[[:space:]]*PLOZZ_SENTRY_DSN=' "$env_file" | tail -n1 || true)
    [ -n "$dsn_line" ] || continue
    candidate=$(printf '%s' "$dsn_line" \
      | sed -E "s/^[[:space:]]*PLOZZ_SENTRY_DSN=//; s/^\"//; s/\"$//; s/^'//; s/'$//")
    if [ -n "$candidate" ]; then
      PLOZZ_SENTRY_DSN="$candidate"
      export PLOZZ_SENTRY_DSN
      echo "Read PLOZZ_SENTRY_DSN from ${env_file}"
      break
    fi
  done
fi

# --- Opt-in crash-reporting DSN bake -----------------------------------------
# If PLOZZ_SENTRY_DSN is set in the environment, bake it into the generated
# project so CrashReporting can read it from Info.plist at runtime. When unset
# the project.yml default ("") is left in place and the app never sends anything.
# The DSN is a secret-ish URL (contains '/', ':', '@') so we use '|' as the sed
# delimiter and escape the few characters sed treats specially in a replacement.
if [ -n "${PLOZZ_SENTRY_DSN:-}" ]; then
  if [ -f "$proj" ]; then
    esc_dsn=$(printf '%s' "${PLOZZ_SENTRY_DSN}" | sed -e 's/[\\&|]/\\&/g')
    /usr/bin/sed -i '' -E "s|PLOZZ_SENTRY_DSN = [^;]*;|PLOZZ_SENTRY_DSN = \"${esc_dsn}\";|g" "$proj"
    echo "Baked PLOZZ_SENTRY_DSN into ${proj} (crash reporting endpoint configured)"
  else
    echo "warning: $proj not found; skipping DSN bake"
  fi
fi

# --- Release channel bake ----------------------------------------------------
# The runtime fallback for "is this a TestFlight build?" sniffs
# `Bundle.main.appStoreReceiptURL`, which on tvOS can be nil (a receipt is only
# written after a purchase) — so a TestFlight install could read as production
# and silently default crash reporting OFF. The fastlane `beta`/`release` lanes
# set PLOZZ_RELEASE_CHANNEL so the answer is decided at build time instead.
release_channel="${PLOZZ_RELEASE_CHANNEL:-}"
if [ -n "$release_channel" ]; then
  case "$release_channel" in
    testflight|production) ;;
    *)
      echo "error: PLOZZ_RELEASE_CHANNEL must be 'testflight' or 'production' (got '${release_channel}')" >&2
      exit 1
      ;;
  esac
fi
if [ -f "$proj" ]; then
  /usr/bin/sed -i '' -E "s|PLOZZ_RELEASE_CHANNEL = [^;]*;|PLOZZ_RELEASE_CHANNEL = \"${release_channel}\";|g" "$proj"
  if [ -n "$release_channel" ]; then
    echo "Baked PLOZZ_RELEASE_CHANNEL = ${release_channel} into ${proj}"
  fi
else
  echo "warning: $proj not found; skipping release-channel bake"
fi

# --- Release-notes id bake ---------------------------------------------------
# Distribution lanes select one committed ReleaseNotes.json entry. Baking that
# stable id into Info.plist lets the app distinguish real shipped releases from
# local builds and from another TestFlight build using the same CalVer date.
release_id="${PLOZZ_RELEASE_ID:-}"
if [ -n "$release_id" ]; then
  if ! printf '%s' "$release_id" | grep -Eq '^release/[0-9]{3,}$'; then
    echo "error: PLOZZ_RELEASE_ID must match release/<build> (got '${release_id}')" >&2
    exit 1
  fi
fi
if [ -f "$proj" ]; then
  esc_release_id=$(printf '%s' "$release_id" | sed -e 's/[\\&|]/\\&/g')
  /usr/bin/sed -i '' -E "s|PLOZZ_RELEASE_ID = [^;]*;|PLOZZ_RELEASE_ID = \"${esc_release_id}\";|g" "$proj"
  if [ -n "$release_id" ]; then
    echo "Baked PLOZZ_RELEASE_ID = ${release_id} into ${proj}"
  fi
else
  echo "warning: $proj not found; skipping release-id bake"
fi

if [ -n "${PLOZZ_BUILD_NUMBER:-}" ]; then
  build="${PLOZZ_BUILD_NUMBER}"
  src="PLOZZ_BUILD_NUMBER override"
elif build="$(git rev-list --count HEAD 2>/dev/null)" && [ -n "$build" ]; then
  src="git commit count"
  # Committed builds get the clean integer commit count (2559). But an uncommitted
  # working tree keeps the SAME commit count across rebuilds, and tvOS/devicectl
  # silently dedups an install when CFBundleVersion is unchanged — so changed-but-
  # uncommitted code never actually lands on the Apple TV. Fix: while the tree is
  # dirty, append a monotonic ".N" dev suffix (2559.1, 2559.2, …) so every rebuild
  # is a distinct, strictly-increasing CFBundleVersion the installer can't skip.
  # A real commit bumps the base count and drops the suffix again.
  if [ -n "$(git status --porcelain 2>/dev/null)" ]; then
    counter_file=".plozz-dev-build"   # gitignored, per-worktree
    dev_n=1
    if [ -f "$counter_file" ]; then
      # Stored as "<commitCount> <lastN>". Continue the sequence for the same
      # commit count; restart at 1 whenever the base count has moved.
      stored_base="$(awk '{print $1}' "$counter_file" 2>/dev/null || true)"
      stored_n="$(awk '{print $2}' "$counter_file" 2>/dev/null || true)"
      if [ "$stored_base" = "$build" ] && [ -n "$stored_n" ]; then
        dev_n=$((stored_n + 1))
      fi
    fi
    printf '%s %s\n' "$build" "$dev_n" > "$counter_file"
    build="${build}.${dev_n}"
    src="git commit count + dirty-tree dev suffix"
  fi
else
  echo "warning: could not determine a build number (no PLOZZ_BUILD_NUMBER and git unavailable); leaving CFBundleVersion at the project.yml default"
  exit 0
fi

proj="Plozz.xcodeproj/project.pbxproj"
if [ ! -f "$proj" ]; then
  echo "warning: $proj not found; skipping build-number bake"
  exit 0
fi

/usr/bin/sed -i '' -E "s/CURRENT_PROJECT_VERSION = [^;]*;/CURRENT_PROJECT_VERSION = ${build};/g" "$proj"
echo "Baked CFBundleVersion (CURRENT_PROJECT_VERSION) = ${build} (from ${src}) into ${proj}"

# --- Apple version and independently displayed Plozz release ------------------
# The catalog owns the stable Apple version. A selected release additionally
# supplies its display date; local builds never allocate a public release.
set -- identity
if [ -n "$release_channel" ] && [ -z "$release_id" ]; then
  echo "error: distribution builds require PLOZZ_RELEASE_ID" >&2
  exit 1
fi
if [ -n "$release_id" ]; then
  set -- "$@" --release-id "$release_id" --build "$build"
fi
if [ -n "${PLOZZ_MARKETING_VERSION:-}" ]; then
  set -- "$@" --version "$PLOZZ_MARKETING_VERSION"
fi
identity="$(python3 tools/release-notes.py "$@")"
marketing="$(printf '%s' "$identity" | python3 -c 'import json,sys; print(json.load(sys.stdin)["marketingVersion"])')"
release_version="$(printf '%s' "$identity" | python3 -c 'import json,sys; print(json.load(sys.stdin)["releaseVersion"])')"

/usr/bin/sed -i '' -E "s/MARKETING_VERSION = [^;]*;/MARKETING_VERSION = ${marketing};/g" "$proj"
/usr/bin/sed -i '' -E "s/PLOZZ_RELEASE_VERSION = [^;]*;/PLOZZ_RELEASE_VERSION = \"${release_version}\";/g" "$proj"
echo "Baked Apple version ${marketing}, Plozz release ${release_version:-local build} into ${proj}"
