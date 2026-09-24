#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HELPER="$ROOT/tools/lib/apple_build_lease.py"
SHELL_LIB="$ROOT/tools/lib/apple-build-lease.sh"
WRAPPER="$ROOT/tools/with-apple-build-lease.sh"
TMP="$(mktemp -d -t plozz-build-interlock-tests)"
FIXTURE_PIDS=()

cleanup() {
  local pid
  for pid in "${FIXTURE_PIDS[@]:-}"; do
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
      kill "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
    fi
  done
  rm -rf "$TMP"
}
trap cleanup EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_exists() {
  [[ -e "$1" ]] || fail "expected path to exist: $1"
}

assert_missing() {
  [[ ! -e "$1" ]] || fail "expected path to be absent: $1"
}

assert_contains() {
  grep -F "$2" "$1" >/dev/null || fail "expected '$2' in $1"
}

assert_source_contains() {
  grep -F "$2" "$ROOT/$1" >/dev/null || fail "expected writer lease '$2' in $1"
}

new_home() {
  local name="$1" home root
  home="$TMP/$name/home"
  mkdir -p "$home"
  chmod 700 "$home"
  root="$(lease_root "$home")"
  mkdir -p "$(dirname "$root")"
  : > "$(dirname "$root")/.apple-build-interlock-test-root"
  chmod 600 "$(dirname "$root")/.apple-build-interlock-test-root"
  printf '%s\n' "$home"
}

lease_root() {
  printf '%s/.config/smart-disk-maintenance/apple-build-interlock-v1\n' "$1"
}

test_env() {
  local home="$1"
  shift
  env \
    HOME="$home" \
    APPLE_BUILD_INTERLOCK_TESTING=1 \
    APPLE_BUILD_INTERLOCK_TEST_ROOT="$(lease_root "$home")" \
    "$@"
}

record_count() {
  local leases
  leases="$(lease_root "$1")/leases"
  [[ -d "$leases" ]] || { echo 0; return; }
  find "$leases" -mindepth 1 -maxdepth 1 -type f -name '*.json' | wc -l | tr -d ' '
}

wait_for_file() {
  local path="$1" attempts="${2:-100}" i
  for ((i = 0; i < attempts; i++)); do
    [[ -e "$path" ]] && return 0
    sleep 0.05
  done
  fail "timed out waiting for $path"
}

wait_for_no_records() {
  local home="$1" attempts="${2:-100}" i
  for ((i = 0; i < attempts; i++)); do
    [[ "$(record_count "$home")" == "0" ]] && return 0
    sleep 0.05
  done
  test_env "$home" /usr/bin/python3 "$HELPER" inspect >&2 || true
  fail "lease records did not clear under $home"
}

write_rollout() {
  local home="$1" root
  root="$(lease_root "$home")"
  test_env "$home" /usr/bin/python3 "$HELPER" prepare
  test_env "$home" /usr/bin/python3 "$HELPER" required-rollout > "$root/rollout-policy-v1"
  chmod 600 "$root/rollout-policy-v1"
}

start_shared() {
  local home="$1" owner="$2" ready="$3" release="$4"
  test_env "$home" "$WRAPPER" "$owner" -- /bin/sh -c '
    touch "$1"
    while [ ! -e "$2" ]; do sleep 0.05; done
  ' _ "$ready" "$release" >/dev/null 2>&1 &
  LAST_PID=$!
  FIXTURE_PIDS+=("$LAST_PID")
}

start_exclusive() {
  local home="$1" owner="$2" ready="$3" release="$4"
  test_env "$home" "$WRAPPER" --exclusive "$owner" -- /bin/sh -c '
    touch "$1"
    while [ ! -e "$2" ]; do sleep 0.05; done
  ' _ "$ready" "$release" >/dev/null 2>&1 &
  LAST_PID=$!
  FIXTURE_PIDS+=("$LAST_PID")
}

exclusive_probe() {
  local home="$1"
  test_env "$home" "$WRAPPER" --exclusive test/exclusive-probe -- /usr/bin/true \
    >/dev/null 2>&1
}

# Production identity must use one captured effective UID and the physical
# passwd home, not real UID, caller HOME, or a symlink spelling.
/usr/bin/python3 - "$HELPER" "$TMP" <<'PY'
import importlib.util
import os
import sys
from pathlib import Path
from types import SimpleNamespace
from unittest import mock

helper = Path(sys.argv[1])
tmp = Path(sys.argv[2])
effective_uid = 22222
real_uid = 11111

spec = importlib.util.spec_from_file_location("apple_build_lease_identity_test", helper)
module = importlib.util.module_from_spec(spec)
with mock.patch("os.geteuid", return_value=effective_uid), mock.patch(
    "os.getuid", return_value=real_uid
):
    spec.loader.exec_module(module)

if module.EFFECTIVE_UID != effective_uid:
    raise SystemExit("helper did not capture the effective UID")

physical_home = tmp / "physical-passwd-home"
physical_home.mkdir()
alias_home = tmp / "symlink-passwd-home"
alias_home.symlink_to(physical_home, target_is_directory=True)

for name in ("APPLE_BUILD_INTERLOCK_TEST_ROOT", "APPLE_BUILD_INTERLOCK_TESTING"):
    os.environ.pop(name, None)
os.environ["HOME"] = str(tmp / "caller-home")

with mock.patch.object(
    module.pwd,
    "getpwuid",
    side_effect=lambda uid: (
        SimpleNamespace(pw_dir=str(alias_home))
        if uid == effective_uid
        else (_ for _ in ()).throw(AssertionError(f"unexpected uid {uid}"))
    ),
):
    resolved = module.paths()

if resolved["home"] != physical_home.resolve(strict=True):
    raise SystemExit("passwd home was not physically resolved")
if resolved["root"] != physical_home.resolve(strict=True) / ".config" / "smart-disk-maintenance" / module.ROOT_NAME:
    raise SystemExit("production namespace did not use the resolved passwd home")

module._check_owned(SimpleNamespace(st_uid=effective_uid), "effective-owner")
try:
    module._check_owned(SimpleNamespace(st_uid=real_uid), "real-owner")
except module.LeaseError:
    pass
else:
    raise SystemExit("real UID was accepted instead of effective UID")
PY

# A test capability cannot pair a temporary lock namespace with another HOME.
TEST_ROOT_HOME="$(new_home test-root-home)"
TEST_OTHER_HOME="$(new_home test-other-home)"
set +e
HOME="$TEST_OTHER_HOME" \
APPLE_BUILD_INTERLOCK_TESTING=1 \
APPLE_BUILD_INTERLOCK_TEST_ROOT="$(lease_root "$TEST_ROOT_HOME")" \
  /usr/bin/python3 "$HELPER" path root >"$TMP/mismatched-test-home.log" 2>&1
MISMATCHED_TEST_HOME_STATUS=$?
set -e
[[ "$MISMATCHED_TEST_HOME_STATUS" -ne 0 ]] ||
  fail "test interlock accepted a lock namespace from another HOME"
assert_contains "$TMP/mismatched-test-home.log" "must belong to the test HOME fixture"

# Normal operation ignores caller-controlled HOME and resolves one canonical
# per-uid host namespace. Fixture roots require the explicit test capability.
CANONICAL_ONE="$(HOME="$TMP/fake-home-one" /usr/bin/python3 "$HELPER" path root)"
CANONICAL_TWO="$(HOME="$TMP/fake-home-two" /usr/bin/python3 "$HELPER" path root)"
[[ "$CANONICAL_ONE" == "$CANONICAL_TWO" ]] || fail "HOME split the production interlock namespace"
[[ "$CANONICAL_ONE" != "$TMP/"* ]] || fail "production interlock resolved into fixture HOME"

# Simultaneous first use must create one stable namespace and allow both readers.
HOME_FIRST="$(new_home simultaneous-first)"
R1_READY="$TMP/r1.ready"; R1_RELEASE="$TMP/r1.release"
R2_READY="$TMP/r2.ready"; R2_RELEASE="$TMP/r2.release"
start_shared "$HOME_FIRST" test/reader-one "$R1_READY" "$R1_RELEASE"; R1_PID="$LAST_PID"
start_shared "$HOME_FIRST" test/reader-two "$R2_READY" "$R2_RELEASE"; R2_PID="$LAST_PID"
wait_for_file "$R1_READY"
wait_for_file "$R2_READY"
[[ "$(record_count "$HOME_FIRST")" == "2" ]] || fail "concurrent readers did not both acquire"
write_rollout "$HOME_FIRST"
if exclusive_probe "$HOME_FIRST"; then
  fail "exclusive cleanup acquired while readers were active"
fi
touch "$R1_RELEASE" "$R2_RELEASE"
wait "$R1_PID"; wait "$R2_PID"
wait_for_no_records "$HOME_FIRST"

# An exclusive owner blocks a reader until the writer has fully released.
HOME_WRITER="$(new_home writer-blocks-reader)"
write_rollout "$HOME_WRITER"
W_READY="$TMP/writer.ready"; W_RELEASE="$TMP/writer.release"
BLOCKED_READY="$TMP/blocked-reader.ready"; BLOCKED_RELEASE="$TMP/blocked-reader.release"
start_exclusive "$HOME_WRITER" test/exclusive-owner "$W_READY" "$W_RELEASE"; W_PID="$LAST_PID"
wait_for_file "$W_READY"
start_shared "$HOME_WRITER" test/blocked-reader "$BLOCKED_READY" "$BLOCKED_RELEASE"; BLOCKED_PID="$LAST_PID"
sleep 0.3
assert_missing "$BLOCKED_READY"
touch "$W_RELEASE"
wait "$W_PID"
wait_for_file "$BLOCKED_READY"
touch "$BLOCKED_RELEASE"
wait "$BLOCKED_PID"
wait_for_no_records "$HOME_WRITER"

# The outer lease remains held across deliberate no-process release-lane gaps.
HOME_GAP="$(new_home release-gap)"
write_rollout "$HOME_GAP"
GAP_READY="$TMP/gap.ready"; GAP_CONTINUE="$TMP/gap.continue"; GAP_DONE="$TMP/gap.done"
test_env "$HOME_GAP" "$WRAPPER" test/release-lane -- /bin/sh -c '
  touch "$1"
  while [ ! -e "$2" ]; do sleep 0.05; done
  touch "$3"
' _ "$GAP_READY" "$GAP_CONTINUE" "$GAP_DONE" >/dev/null 2>&1 &
GAP_PID=$!; FIXTURE_PIDS+=("$GAP_PID")
wait_for_file "$GAP_READY"
if exclusive_probe "$HOME_GAP"; then
  fail "exclusive cleanup acquired during a release-lane gap"
fi
touch "$GAP_CONTINUE"
wait "$GAP_PID"
assert_exists "$GAP_DONE"
wait_for_no_records "$HOME_GAP"

# Fastlane's Ruby client holds the same shared kernel lock across its whole block.
HOME_RUBY="$(new_home ruby-release-gap)"
write_rollout "$HOME_RUBY"
RUBY_READY="$TMP/ruby.ready"; RUBY_CONTINUE="$TMP/ruby.continue"; RUBY_DONE="$TMP/ruby.done"
test_env "$HOME_RUBY" ruby -I"$ROOT/tools/lib" -rapple_build_lease -e '
  AppleBuildLease.with_shared("test/ruby-release") do
    File.write(ARGV[0], "ready\n")
    sleep 0.05 until File.exist?(ARGV[1])
    File.write(ARGV[2], "done\n")
  end
' "$RUBY_READY" "$RUBY_CONTINUE" "$RUBY_DONE" >/dev/null 2>&1 &
RUBY_PID=$!; FIXTURE_PIDS+=("$RUBY_PID")
wait_for_file "$RUBY_READY"
if exclusive_probe "$HOME_RUBY"; then
  fail "exclusive cleanup acquired during Ruby release-lane gap"
fi
touch "$RUBY_CONTINUE"
wait "$RUBY_PID"
assert_exists "$RUBY_DONE"
wait_for_no_records "$HOME_RUBY"

# Ruby publishes inheritable descriptor metadata to Fastlane children. A nested
# shell reuses the same record, and an asynchronous child keeps the lock after
# the Ruby owner records clean completion and exits.
HOME_RUBY_CHILD="$(new_home ruby-child-inheritance)"
write_rollout "$HOME_RUBY_CHILD"
RUBY_NESTED_RESULT="$TMP/ruby-nested.result"
RUBY_CHILD_READY="$TMP/ruby-child.ready"
RUBY_CHILD_RELEASE="$TMP/ruby-child.release"
RUBY_CHILD_PID_FILE="$TMP/ruby-child.pid"
test_env "$HOME_RUBY_CHILD" ruby -I"$ROOT/tools/lib" -rapple_build_lease -e '
  AppleBuildLease.with_shared("test/ruby-child-parent") do
    ok = system(
      "/bin/bash",
      "-c",
      %q{
        source "$1"
        acquire_apple_build_shared_lease test/ruby-child-nested
        count=$(find "$HOME/.config/smart-disk-maintenance/apple-build-interlock-v1/leases" \
          -mindepth 1 -maxdepth 1 -type f -name "*.json" | wc -l | tr -d " ")
        printf "%s %s\n" "$APPLE_BUILD_LEASE_LOCAL_ROLE" "$count" > "$2"
        release_apple_build_lease
      },
      "_",
      ARGV[0],
      ARGV[1]
    )
    raise "nested shell failed" unless ok
    pid = Process.spawn(
      "/bin/sh",
      "-c",
      "touch \"$1\"; while [ ! -e \"$2\" ]; do sleep 0.05; done",
      "_",
      ARGV[2],
      ARGV[3]
    )
    File.write(ARGV[4], "#{pid}\n")
    Process.detach(pid)
  end
  unless AppleBuildLease::ENV_KEYS.none? { |name| ENV.key?(name) }
    raise "Ruby lease environment was not cleared"
  end
' "$SHELL_LIB" "$RUBY_NESTED_RESULT" "$RUBY_CHILD_READY" "$RUBY_CHILD_RELEASE" "$RUBY_CHILD_PID_FILE"
assert_contains "$RUBY_NESTED_RESULT" "inherited 1"
wait_for_file "$RUBY_CHILD_READY"
RUBY_CHILD_PID="$(cat "$RUBY_CHILD_PID_FILE")"
FIXTURE_PIDS+=("$RUBY_CHILD_PID")
if exclusive_probe "$HOME_RUBY_CHILD"; then
  fail "Ruby owner release dropped the lease while an inherited child was alive"
fi
touch "$RUBY_CHILD_RELEASE"
wait_for_no_records "$HOME_RUBY_CHILD"

# Nested scripts validate and reuse the inherited descriptor instead of adding a
# second record or trusting environment strings alone.
HOME_NESTED="$(new_home nested)"
NESTED_RESULT="$TMP/nested.result"
test_env "$HOME_NESTED" "$WRAPPER" test/outer -- /bin/bash -c '
  source "$1"
  acquire_apple_build_shared_lease test/inner
  count=$(find "$HOME/.config/smart-disk-maintenance/apple-build-interlock-v1/leases" \
    -mindepth 1 -maxdepth 1 -type f -name "*.json" | wc -l | tr -d " ")
  printf "%s %s\n" "$APPLE_BUILD_LEASE_LOCAL_ROLE" "$count" > "$2"
  release_apple_build_lease
' _ "$SHELL_LIB" "$NESTED_RESULT"
assert_contains "$NESTED_RESULT" "inherited 1"
wait_for_no_records "$HOME_NESTED"

# Exec replacement keeps the requester PID and may perform the final release.
HOME_EXEC="$(new_home exec-owner)"
EXEC_RESULT="$TMP/exec.result"
test_env "$HOME_EXEC" /bin/bash -c '
  source "$1"
  acquire_apple_build_shared_lease test/exec-parent
  exec /bin/bash -c '"'"'
    source "$1"
    acquire_apple_build_shared_lease test/exec-child
    printf "%s\n" "$APPLE_BUILD_LEASE_LOCAL_ROLE" > "$2"
    release_apple_build_lease
  '"'"' _ "$1" "$2"
' _ "$SHELL_LIB" "$EXEC_RESULT"
assert_contains "$EXEC_RESULT" "owner"
wait_for_no_records "$HOME_EXEC"

# Parent release does not drop the kernel lock while an inherited child lives.
HOME_CHILD="$(new_home child-outlives-parent)"
write_rollout "$HOME_CHILD"
CHILD_PID_FILE="$TMP/outliving-child.pid"
test_env "$HOME_CHILD" /bin/bash -c '
  source "$1"
  acquire_apple_build_shared_lease test/outliving-parent
  /bin/sleep 1.2 >/dev/null 2>&1 &
  echo $! > "$2"
  release_apple_build_lease
' _ "$SHELL_LIB" "$CHILD_PID_FILE"
assert_exists "$CHILD_PID_FILE"
if exclusive_probe "$HOME_CHILD"; then
  fail "parent release dropped the lease while an inherited child was alive"
fi
sleep 1.5
wait_for_no_records "$HOME_CHILD"
exclusive_probe "$HOME_CHILD"
wait_for_no_records "$HOME_CHILD"

# Durable identity names the owner/requester and binds both inherited fds.
HOME_IDENTITY="$(new_home identity)"
IDENTITY_READY="$TMP/identity.ready"; IDENTITY_RELEASE="$TMP/identity.release"
start_shared "$HOME_IDENTITY" test/written-identity "$IDENTITY_READY" "$IDENTITY_RELEASE"; IDENTITY_PID="$LAST_PID"
wait_for_file "$IDENTITY_READY"
test_env "$HOME_IDENTITY" /usr/bin/python3 - "$IDENTITY_PID" <<'PY'
import json
import os
import pathlib

root = pathlib.Path.home() / ".config/smart-disk-maintenance/apple-build-interlock-v1"
records = list((root / "leases").glob("*.json"))
assert len(records) == 1
record = json.loads(records[0].read_text())
assert record["protocol"] == 1
assert record["mode"] == "shared"
assert record["state"] == "active"
assert record["owner"] == "test/written-identity"
assert record["request_pid"] > 1
assert record["lock_ino"] > 0 and record["proof_ino"] > 0
assert record["token"] and record["request_start"] and record["cwd"]
PY
touch "$IDENTITY_RELEASE"
wait "$IDENTITY_PID"
wait_for_no_records "$HOME_IDENTITY"

# A forged/stale environment is an error; it must not start a replacement lease.
HOME_FORGED="$(new_home forged-environment)"
FORGED_OK="$TMP/forged.ok"
test_env "$HOME_FORGED" "$WRAPPER" test/forged-parent -- /bin/bash -c '
  source "$1"
  APPLE_BUILD_LEASE_TOKEN=00000000-0000-0000-0000-000000000000
  export APPLE_BUILD_LEASE_TOKEN
  if acquire_apple_build_shared_lease test/forged-child >/dev/null 2>&1; then
    exit 1
  fi
  touch "$2"
' _ "$SHELL_LIB" "$FORGED_OK"
assert_exists "$FORGED_OK"
wait_for_no_records "$HOME_FORGED"

set +e
test_env "$HOME_FORGED" PLOZZ_BUILD_LEASE_WRAPPED=1 \
  /usr/bin/python3 "$ROOT/tools/l10n-sync.py" --validate-only \
  >"$TMP/forged-l10n.log" 2>&1
FORGED_L10N_STATUS=$?
set -e
[[ "$FORGED_L10N_STATUS" -ne 0 ]] || fail "l10n wrapper flag bypassed lease validation"
assert_contains "$TMP/forged-l10n.log" "Invalid inherited Apple build lease environment"

HOME_L10N="$(new_home l10n-wrapper)"
test_env "$HOME_L10N" /usr/bin/python3 "$ROOT/tools/l10n-sync.py" --validate-only \
  >"$TMP/l10n-wrapper.log" 2>&1
assert_contains "$TMP/l10n-wrapper.log" "Catalog validates"
wait_for_no_records "$HOME_L10N"

# Signals and hard crashes leave orphan evidence. A quiet process list is never
# treated as permission to clean.
HOME_SIGNAL="$(new_home signal)"
write_rollout "$HOME_SIGNAL"
SIGNAL_READY="$TMP/signal.ready"
test_env "$HOME_SIGNAL" /bin/bash -c '
  source "$1"
  acquire_apple_build_shared_lease test/signalled
  trap "APPLE_BUILD_LEASE_SIGNALLED=1; abandon_apple_build_lease; exit 143" TERM
  touch "$2"
  while :; do sleep 0.05; done
' _ "$SHELL_LIB" "$SIGNAL_READY" >/dev/null 2>&1 &
SIGNAL_PID=$!; FIXTURE_PIDS+=("$SIGNAL_PID")
wait_for_file "$SIGNAL_READY"
kill -TERM "$SIGNAL_PID"
wait "$SIGNAL_PID" 2>/dev/null || true
if exclusive_probe "$HOME_SIGNAL"; then
  fail "signalled shared lease was mistaken for a safe stale record"
fi
[[ "$(record_count "$HOME_SIGNAL")" == "1" ]] || fail "signal did not retain durable evidence"

HOME_CRASH="$(new_home crash)"
write_rollout "$HOME_CRASH"
CRASH_READY="$TMP/crash.ready"
test_env "$HOME_CRASH" /bin/bash -c '
  source "$1"
  acquire_apple_build_shared_lease test/crashed
  touch "$2"
  while :; do sleep 0.05; done
' _ "$SHELL_LIB" "$CRASH_READY" >/dev/null 2>&1 &
CRASH_PID=$!; FIXTURE_PIDS+=("$CRASH_PID")
wait_for_file "$CRASH_READY"
kill -KILL "$CRASH_PID"
wait "$CRASH_PID" 2>/dev/null || true
sleep 0.1
if exclusive_probe "$HOME_CRASH"; then
  fail "crashed shared lease was mistaken for a safe stale record"
fi
[[ "$(record_count "$HOME_CRASH")" == "1" ]] || fail "crash did not retain durable evidence"

# An ordinary failed wrapped lane also keeps evidence instead of reporting a
# success-shaped release.
HOME_FAILURE="$(new_home failed-lane)"
write_rollout "$HOME_FAILURE"
set +e
test_env "$HOME_FAILURE" "$WRAPPER" test/failed-lane -- /usr/bin/false >/dev/null 2>&1
FAILED_LANE_STATUS=$?
set -e
[[ "$FAILED_LANE_STATUS" -ne 0 ]] || fail "failed wrapped lane reported success"
[[ "$(record_count "$HOME_FAILURE")" == "1" ]] || fail "failed lane did not retain durable evidence"
if exclusive_probe "$HOME_FAILURE"; then
  fail "failed lane evidence was mistaken for cleanup permission"
fi

# Malformed and unknown registry entries fail closed for readers and cleanup.
HOME_MALFORMED="$(new_home malformed)"
test_env "$HOME_MALFORMED" /usr/bin/python3 "$HELPER" prepare
echo "partial" > "$(lease_root "$HOME_MALFORMED")/leases/interrupted.tmp"
set +e
test_env "$HOME_MALFORMED" "$WRAPPER" test/malformed-reader -- /usr/bin/true \
  >"$TMP/malformed.log" 2>&1
MALFORMED_STATUS=$?
set -e
[[ "$MALFORMED_STATUS" -ne 0 ]] || fail "malformed registry entry was ignored"
assert_contains "$TMP/malformed.log" "unknown file in lease registry"

# Replacing the stable lock pathname invalidates the live lease identity.
HOME_REPLACED="$(new_home replaced-lock)"
REPLACED_READY="$TMP/replaced.ready"; REPLACED_CHECK="$TMP/replaced.check"; REPLACED_RESULT="$TMP/replaced.result"
test_env "$HOME_REPLACED" "$WRAPPER" test/replaced-lock -- /bin/bash -c '
  touch "$1"
  while [ ! -e "$2" ]; do sleep 0.05; done
  source "$3"
  if verify_apple_build_lease shared >/dev/null 2>&1; then
    echo unsafe > "$4"
    exit 1
  fi
  echo blocked > "$4"
' _ "$REPLACED_READY" "$REPLACED_CHECK" "$SHELL_LIB" "$REPLACED_RESULT" >/dev/null 2>&1 &
REPLACED_PID=$!; FIXTURE_PIDS+=("$REPLACED_PID")
wait_for_file "$REPLACED_READY"
REPLACED_ROOT="$(lease_root "$HOME_REPLACED")"
mv "$REPLACED_ROOT/coordination.lock" "$REPLACED_ROOT/coordination.lock.original"
: > "$REPLACED_ROOT/coordination.lock"
chmod 600 "$REPLACED_ROOT/coordination.lock"
touch "$REPLACED_CHECK"
wait "$REPLACED_PID" 2>/dev/null || true
assert_contains "$REPLACED_RESULT" "blocked"

# A clean release record is never removed by locking a replacement inode.
HOME_FINALIZER="$(new_home replaced-finalizer-lock)"
FINALIZER_IDENTITY="$TMP/finalizer.identity"
test_env "$HOME_FINALIZER" /bin/bash -c '
  source "$1"
  acquire_apple_build_shared_lease test/finalizer-replacement
  /usr/bin/python3 "$2" request-release \
    --mode "$APPLE_BUILD_LEASE_MODE" \
    --owner "$APPLE_BUILD_LEASE_OWNER" \
    --lease-id "$APPLE_BUILD_LEASE_ID" \
    --token "$APPLE_BUILD_LEASE_TOKEN" \
    --lock-fd 9 --proof-fd 8
  printf "%s %s\n" "$APPLE_BUILD_LEASE_ID" "$APPLE_BUILD_LEASE_TOKEN" > "$3"
  abandon_apple_build_lease
' _ "$SHELL_LIB" "$HELPER" "$FINALIZER_IDENTITY"
read -r FINALIZER_ID FINALIZER_TOKEN < "$FINALIZER_IDENTITY"
FINALIZER_ROOT="$(lease_root "$HOME_FINALIZER")"
mv "$FINALIZER_ROOT/coordination.lock" "$FINALIZER_ROOT/coordination.lock.original"
: > "$FINALIZER_ROOT/coordination.lock"
chmod 600 "$FINALIZER_ROOT/coordination.lock"
set +e
test_env "$HOME_FINALIZER" /usr/bin/python3 "$HELPER" finalize-release \
  --mode shared --lease-id "$FINALIZER_ID" --token "$FINALIZER_TOKEN" \
  >"$TMP/finalizer-replaced.log" 2>&1
FINALIZER_REPLACED_STATUS=$?
set -e
[[ "$FINALIZER_REPLACED_STATUS" -ne 0 ]] ||
  fail "finalizer removed evidence while locking a replacement inode"
[[ "$(record_count "$HOME_FINALIZER")" == "1" ]] ||
  fail "replacement-inode finalizer did not retain lease evidence"
assert_contains "$TMP/finalizer-replaced.log" "replacement coordination lock"

# Missing/incomplete rollout and SUSPENDED each deny exclusive maintenance.
HOME_POLICY="$(new_home policy)"
test_env "$HOME_POLICY" /usr/bin/python3 "$HELPER" prepare
set +e
exclusive_probe "$HOME_POLICY"
MISSING_POLICY_STATUS=$?
set -e
[[ "$MISSING_POLICY_STATUS" -ne 0 ]] || fail "missing rollout policy enabled cleanup"
echo "protocol=1" > "$(lease_root "$HOME_POLICY")/rollout-policy-v1"
chmod 600 "$(lease_root "$HOME_POLICY")/rollout-policy-v1"
set +e
exclusive_probe "$HOME_POLICY"
INCOMPLETE_POLICY_STATUS=$?
set -e
[[ "$INCOMPLETE_POLICY_STATUS" -ne 0 ]] || fail "incomplete rollout policy enabled cleanup"
write_rollout "$HOME_POLICY"
touch "$HOME_POLICY/.config/smart-disk-maintenance/SUSPENDED"
set +e
test_env "$HOME_POLICY" "$WRAPPER" --exclusive test/suspended -- /usr/bin/true \
  >"$TMP/suspended.log" 2>&1
SUSPENDED_STATUS=$?
set -e
[[ "$SUSPENDED_STATUS" -ne 0 ]] || fail "SUSPENDED marker enabled cleanup"
assert_contains "$TMP/suspended.log" "destructive maintenance is suspended"

# Every current Plozz writer surface is statically tied to the protocol. Legacy
# worktrees and other apps remain blocked by rollout policy rather than assumed.
assert_source_contains "fastlane/Fastfile" 'AppleBuildLease.with_shared("plozz/fastlane/generate-project")'
assert_source_contains "fastlane/Fastfile" 'AppleBuildLease.with_shared("plozz/fastlane/build")'
assert_source_contains "fastlane/Fastfile" 'AppleBuildLease.with_shared("plozz/fastlane/beta")'
assert_source_contains "fastlane/Fastfile" 'AppleBuildLease.with_shared("plozz/fastlane/release")'
assert_source_contains "tools/generate-project.sh" 'acquire_apple_build_shared_lease "plozz/generate-project"'
assert_source_contains "tools/deploy-tv.sh" 'acquire_apple_build_shared_lease "plozz/deploy-tv"'
assert_source_contains "tools/deploy-ios.sh" 'acquire_apple_build_shared_lease "plozz/deploy-ios"'
assert_source_contains "tools/run-tests.sh" 'acquire_apple_build_shared_lease "plozz/run-tests"'
assert_source_contains "tools/test-fast.sh" 'acquire_apple_build_shared_lease "plozz/test-fast"'
assert_source_contains "tools/capture-shots.sh" 'acquire_apple_build_shared_lease "plozz/capture-shots"'
assert_source_contains "tools/l10n-guard.sh" 'acquire_apple_build_shared_lease "plozz/l10n-guard"'
assert_source_contains "tools/l10n-prune-stale-products.sh" 'acquire_apple_build_shared_lease "plozz/l10n-prune-stale-products"'
assert_source_contains "tools/l10n-sync.py" '"plozz/l10n-sync"'
assert_source_contains ".github/workflows/ci.yml" 'tools/with-apple-build-lease.sh plozz/ci-tvos-build -- xcodebuild build'

echo "apple build interlock tests passed"
