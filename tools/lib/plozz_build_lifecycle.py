"""Worktree-scoped build storage and durable provenance, not a second deleter."""

from __future__ import annotations

import argparse
from collections.abc import Sequence
import contextlib
import datetime as dt
import fcntl
import json
import os
from pathlib import Path
import plistlib
import pwd
import re
import stat
import subprocess
import sys
import uuid

import apple_build_cleanup as cleanup
import apple_build_lease as lease
import apple_maintenance_policy as policy

VERSION = 1
RETENTION = 7 * 86400
MAX_RESOURCES = 1024
MAX_OWNERS = 128
KINDS = {"derived-data", "package-workspace", "release-evidence"}
STATE_KEYS = {"schema", "epoch", "resources", "retired_contained"}
RESOURCE_KEYS = {
    "id", "identity", "parent", "kind", "owners", "created_at", "observed_at",
    "retired_since", "release_hold",
}
OWNER_KEYS = {"worktree", "parent", "common", "registration", "head"}


def inherited_shared() -> tuple[int, ...]:
    if os.environ.get("APPLE_BUILD_LEASE_PROTOCOL") != "1" or os.environ.get(
        "APPLE_BUILD_LEASE_MODE"
    ) != "shared":
        lease.fail("build registration requires an authenticated shared lease")
    fields = ("owner", "lease_id", "token", "lock_fd", "proof_fd")
    values = {"mode": "shared", "policy_lock_fd": None, "rollout_fd": None}
    for key in fields:
        value = os.environ.get("APPLE_BUILD_LEASE_" + ("ID" if key == "lease_id" else key.upper()))
        if not value:
            lease.fail(f"missing build lease identity: {key}")
        values[key] = int(value) if key.endswith("_fd") else value
    lease.validate_existing(argparse.Namespace(**values))
    return values["lock_fd"], values["proof_fd"]


def git(root: Path, *args: str, common: bool = False) -> bytes:
    command = ["git", "--git-dir=" + str(root)] if common else ["git", "-C", str(root)]
    result = subprocess.run(
        [*command, *args], capture_output=True, timeout=20, check=False,
        env={**os.environ, "GIT_OPTIONAL_LOCKS": "0"},
    )
    if result.returncode:
        lease.fail(f"cannot inspect Git ownership: {root}: {result.stderr.decode(errors='replace')}")
    if len(result.stdout) > policy.MAX_DOCUMENT_BYTES:
        lease.fail("Git ownership inventory exceeds bounded document size")
    return result.stdout


def directory(path: Path, *, create: bool = False, private: bool = False,
              anchor: dict | None = None) -> Path:
    if not path.is_absolute() or ".." in path.parts:
        lease.fail(f"expected an absolute physical directory: {path}")
    # Validate existing ancestors before creating anything through them.
    with cleanup.directory_fd(Path("/")) as root_fd:
        fd = os.dup(root_fd)
        try:
            current = Path("/")
            for component in path.parts[1:]:
                current /= component
                try:
                    child = os.open(component, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=fd)
                except FileNotFoundError:
                    if not create or (anchor and Path(anchor["path"]) not in current.parents):
                        raise
                    os.mkdir(component, mode=0o700, dir_fd=fd)
                    child = os.open(component, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=fd)
                os.close(fd)
                fd = child
                if anchor and current == Path(anchor["path"]):
                    st = os.fstat(fd)
                    if (st.st_dev, st.st_ino) != (anchor["device"], anchor["inode"]):
                        lease.fail("build storage anchor changed while waiting")
            st = os.fstat(fd)
            lease._check_owned(st, str(path))
            if stat.S_IMODE(st.st_mode) & 0o022:
                lease.fail(f"writable-by-others directory: {path}")
            if private:
                lease._check_private_mode(st, str(path))
        finally:
            os.close(fd)
    return policy.physical_path(str(path))


def state_path(*, create: bool = False) -> Path:
    root = lease.paths()["home"] / "Library/Application Support/Plozz/BuildLifecycle"
    return directory(root, create=create, private=True) / "registry.json"


def historical_identity(value: dict) -> Path:
    policy.exact(value, cleanup.IDENTITY_KEYS, "historical directory")
    cleanup.integer(value["device"], "device")
    cleanup.integer(value["inode"], "inode", minimum=1)
    path = Path(policy.text(value["path"], "historical path"))
    if not path.is_absolute() or path != path.resolve(strict=False):
        lease.fail(f"historical path is no longer physical: {path}")
    if os.environ.get("APPLE_BUILD_INTERLOCK_TESTING") == "1":
        if path != lease.paths()["home"] and lease.paths()["home"] not in path.parents:
            lease.fail("lifecycle path escapes fixture HOME")
    return path


def read_state(path: Path) -> dict:
    state = policy.document(policy.read_bytes(path, private=True))
    policy.exact(state, STATE_KEYS, "build lifecycle registry")
    if type(state["schema"]) is not int or state["schema"] != VERSION:
        lease.fail("unsupported build lifecycle registry")
    cleanup.integer(state["epoch"], "registry epoch")
    cleanup.integer(state["retired_contained"], "retired contained count")
    resources = state["resources"]
    if not isinstance(resources, list) or len(resources) > MAX_RESOURCES:
        lease.fail("build lifecycle resource limit exceeded")
    paths, ids = set(), set()
    for resource in resources:
        policy.exact(resource, RESOURCE_KEYS, "build resource")
        path = historical_identity(resource["identity"])
        historical_identity(resource["parent"])
        lease.validate_uuid(resource["id"], "resource epoch")
        if path in paths or resource["id"] in ids:
            lease.fail("duplicate build resource")
        paths.add(path)
        ids.add(resource["id"])
        if resource["kind"] not in KINDS or type(resource["release_hold"]) is not bool:
            lease.fail("invalid build resource kind or release hold")
        for key in ("created_at", "observed_at"):
            policy.timestamp(resource[key])
        if policy.timestamp(resource["created_at"]) > policy.timestamp(resource["observed_at"]):
            lease.fail("resource observation predates creation")
        if resource["retired_since"] is not None:
            if policy.timestamp(resource["retired_since"]) < policy.timestamp(resource["observed_at"]):
                lease.fail("resource retirement predates last live observation")
        owners = resource["owners"]
        if not isinstance(owners, list) or not 1 <= len(owners) <= MAX_OWNERS:
            lease.fail("invalid build resource owners")
        owner_ids = set()
        for owner in owners:
            policy.exact(owner, OWNER_KEYS, "build resource owner")
            for key in ("worktree", "parent", "common", "registration"):
                historical_identity(owner[key])
            if not isinstance(owner["head"], str) or not re.fullmatch(r"[0-9a-f]{40}", owner["head"]):
                lease.fail("owner HEAD must be an exact Git commit")
            token = policy.canonical(owner["worktree"])
            if token in owner_ids:
                lease.fail("duplicate resource owner")
            owner_ids.add(token)
    return state


def publish(path: Path, payload: bytes) -> None:
    if len(payload) > policy.MAX_DOCUMENT_BYTES:
        lease.fail("build lifecycle registry exceeds 4 MiB; no state was discarded")
    with cleanup.directory_fd(path.parent) as fd:
        temporary = ".registry-" + str(uuid.uuid4()) + ".tmp"
        out = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600, dir_fd=fd)
        try:
            try:
                cleanup.write_all(out, payload)
                os.fsync(out)
            finally:
                os.close(out)
            os.replace(temporary, path.name, src_dir_fd=fd, dst_dir_fd=fd)
            os.fsync(fd)
        finally:
            with contextlib.suppress(FileNotFoundError):
                os.unlink(temporary, dir_fd=fd)


@contextlib.contextmanager
def registry():
    inherited_shared()
    path = state_path(create=True)
    fd = lease._open_regular_file(path.parent / "registry.lock", os.O_CREAT | os.O_RDWR)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX)
        lease.validate_fd_path(fd, path.parent / "registry.lock", private=True)
        if path.exists() or path.is_symlink():
            state = read_state(path)
        else:
            # A surviving lock is not enough to identify loss of the registry;
            # the initialization marker makes subsequent missing state an error.
            marker = path.parent / "initialized"
            if marker.exists() or marker.is_symlink():
                lease.fail("build lifecycle registry is missing after initialization")
            state = {"schema": VERSION, "epoch": 0, "resources": [], "retired_contained": 0}
        yield state
        state["epoch"] += 1
        inherited_shared()
        lease.validate_fd_path(fd, path.parent / "registry.lock", private=True)
        publish(path, policy.canonical(state) + b"\n")
        marker = path.parent / "initialized"
        if not marker.exists():
            cleanup.write_private_new(marker, b"1\n")
    finally:
        os.close(fd)


def owner_snapshot(repo: Path) -> dict:
    repo = directory(repo)
    actual = git(repo, "rev-parse", "--show-toplevel").decode().strip()
    if actual != str(repo):
        lease.fail("build owner must be an exact physical worktree root")
    common = Path(git(repo, "rev-parse", "--path-format=absolute", "--git-common-dir").decode().strip())
    registration = Path(git(repo, "rev-parse", "--absolute-git-dir").decode().strip())
    _, registered = policy.worktree_snapshot(repo)
    if str(repo) not in registered:
        lease.fail("build owner is absent from its Git worktree registry")
    return {
        "worktree": policy.identity(repo), "parent": policy.identity(repo.parent),
        "common": policy.identity(common), "registration": policy.identity(registration),
        "head": git(repo, "rev-parse", "HEAD").decode().strip(),
    }


def owner_status(owner: dict) -> str:
    worktree = historical_identity(owner["worktree"])
    common = historical_identity(owner["common"])
    registration = historical_identity(owner["registration"])
    cleanup.validate_identity(owner["common"], "repository common directory")
    cleanup.validate_identity(owner["parent"], "worktree parent/mounted volume")
    data = git(common, "worktree", "list", "--porcelain", "-z", common=True)
    registered = {
        field[len("worktree "):] for field in data.decode().split("\0")
        if field.startswith("worktree ")
    }
    if worktree.exists() or worktree.is_symlink():
        if policy.identity(worktree) != owner["worktree"]:
            return "protected: worktree path restored or replaced"
        return "protected: living worktree"
    if str(worktree) in registered:
        return "protected: still registered (including prunable/offline worktrees)"
    if registration.exists() or registration.is_symlink():
        return "protected: registration survives; owner may have moved"
    if registration == common:
        return "protected: primary checkout"
    # Git move preserves the registration identity. Missing parents or mounted
    # filesystems cannot establish retirement. No PID/mtime inference is used.
    return "retired"


def resource_status(resource: dict, cache: dict | None = None) -> str:
    if resource["release_hold"] or resource["kind"] == "release-evidence":
        return "protected: durable release evidence"
    for owner in resource["owners"]:
        key = policy.canonical({key: value for key, value in owner.items() if key != "head"})
        if cache is not None and key in cache:
            status = cache[key]
        else:
            status = owner_status(owner)
            if cache is not None:
                cache[key] = status
        if status != "retired":
            return status
    return "retired"


def reconcile(state: dict, now: dt.datetime) -> list[dict]:
    results, retained = [], []
    cache = {}
    for resource in state["resources"]:
        path = historical_identity(resource["identity"])
        try:
            status = resource_status(resource, cache)
            if path.exists() or path.is_symlink():
                cleanup.validate_identity(resource["identity"], "owned build root")
            elif status == "retired" and all(
                Path(owner["worktree"]["path"]) in path.parents for owner in resource["owners"]
            ):
                state["retired_contained"] += 1
                continue
            else:
                status = "protected: resource missing; external disappearance is not retirement"
        except (OSError, ValueError, lease.LeaseError, subprocess.SubprocessError) as exc:
            status = f"blocked: {exc}"
        if status == "retired":
            resource["retired_since"] = resource["retired_since"] or cleanup.utc(now)
            age = (now - policy.timestamp(resource["retired_since"])).total_seconds()
            if age < RETENTION:
                status = "retired: seven-day observation retention pending"
            else:
                status = "retired: exact compiler-output proposal available; approval required"
        else:
            resource["retired_since"] = None
        results.append({"path": str(path), "kind": resource["kind"], "status": status})
        retained.append(resource)
    state["resources"] = retained
    return results


def existing_parent(path: Path) -> dict:
    parent = path.parent
    while not parent.exists() and not parent.is_symlink():
        if parent == parent.parent:
            lease.fail("external build path has no existing parent")
        parent = parent.parent
    return policy.identity(directory(parent))


def register(repo: Path, roots: list[tuple[str, Path]],
             private_children: Sequence[tuple[Path, Path]] = ()) -> list[dict]:
    inherited_shared()
    owner = owner_snapshot(repo)
    now = cleanup.now_utc()
    anchors = {
        path: owner["worktree"] if repo in path.parents else (
            policy.identity(lease.paths()["home"]) if kind == "release-evidence"
            else existing_parent(path)
        )
        for kind, path in roots
    }
    with registry() as state:
        if owner_snapshot(repo) != owner:
            lease.fail("worktree changed while waiting for metadata publication")
        reconcile(state, now)
        for kind, path in roots:
            if kind not in KINDS:
                lease.fail(f"unknown generated root kind: {kind}")
            previously_missing = not path.exists() and not path.is_symlink()
            anchor = anchors[path]
            path = directory(path, create=True, anchor=anchor)
            cleanup.validate_identity(anchor, "build storage anchor")
            if owner_snapshot(repo) != owner:
                lease.fail("worktree changed while registering generated storage")
            if path == repo or path in repo.parents:
                lease.fail("build resource cannot contain its owning checkout")
            if Path(owner["common"]["path"]) == path or Path(owner["common"]["path"]) in path.parents:
                lease.fail("Git data cannot be a build resource")
            if repo in path.parents:
                relative = str(path.relative_to(repo))
                if git(repo, "ls-files", "-z", "--", ":(literal)" + relative):
                    lease.fail("build resource contains tracked source")
                if not git(repo, "check-ignore", "--no-index", "--", relative).strip():
                    lease.fail("worktree build resource must be ignored by Git")
            identity = policy.identity(path)
            resource = next((r for r in state["resources"] if r["identity"]["path"] == str(path)), None)
            if resource is not None and resource["identity"] != identity and previously_missing and repo in path.parents:
                if len(resource["owners"]) != 1 or any(
                    resource["owners"][0][key] != owner[key] for key in OWNER_KEYS - {"head"}
                ):
                    lease.fail("missing shared or rebound build resource requires review")
                state["resources"].remove(resource)
                resource = None
            if resource is None:
                if repo not in path.parents and not previously_missing:
                    with os.scandir(path) as children:
                        nonempty = next(children, None) is not None
                    if nonempty:
                        if kind != "derived-data":
                            lease.fail("existing external resource has no generated-root provenance")
                        cleanup.validate_target_location("xcode-derived-data", path / "Build", repo)
                if len(state["resources"]) >= MAX_RESOURCES:
                    lease.fail("build lifecycle resource limit reached; reconcile retired worktrees")
                resource = {
                    "id": str(uuid.uuid4()), "identity": identity, "parent": policy.identity(path.parent),
                    "kind": kind, "owners": [],
                    "created_at": cleanup.utc(now), "observed_at": cleanup.utc(now),
                    "retired_since": None, "release_hold": kind == "release-evidence",
                }
                state["resources"].append(resource)
            if resource["identity"] != identity or resource["kind"] != kind:
                lease.fail(f"owned build root replaced or repurposed: {path}")
            cleanup.validate_identity(resource["parent"], "build resource parent")
            matches = [o for o in resource["owners"] if o["worktree"] == owner["worktree"]]
            if matches:
                if matches[0]["common"] != owner["common"] or matches[0]["registration"] != owner["registration"]:
                    lease.fail("owner registration identity changed")
                matches[0]["head"] = owner["head"]
            else:
                if len(resource["owners"]) >= MAX_OWNERS:
                    lease.fail("shared resource owner limit reached")
                resource["owners"].append(owner)
            resource["observed_at"] = cleanup.utc(now)
            resource["retired_since"] = None
        containers = {
            Path(resource["identity"]["path"]): resource for resource in state["resources"]
            if (resource["kind"], Path(resource["identity"]["path"])) in roots
            and resource["kind"] != "release-evidence"
        }
        for container, child in private_children:
            if container not in containers or container not in child.parents:
                lease.fail("private writer path must descend from a nominated build container")
            resource = containers[container]
            directory(child, create=True, anchor=resource["identity"])
            cleanup.validate_identity(resource["identity"], "private writer container")
            cleanup.validate_identity(resource["parent"], "private writer container parent")
        if owner_snapshot(repo) != owner:
            lease.fail("worktree changed while preparing private writer paths")
        result = reconcile(state, now)
        for notice in result:
            if notice["status"].startswith(("blocked:", "retired:")):
                print(f"build storage: {notice['path']}: {notice['status']}", file=sys.stderr)
        return result


def workspace_settings(repo: Path, project: Path) -> None:
    inherited_shared()
    derived = repo / ".build/xcode-gui"
    roots = [("derived-data", derived)]
    for item in legacy_inventory():
        if item.get("workspace") in {str(project), str(project / "project.xcworkspace")}:
            roots.append(("derived-data", Path(item["path"])))
    register(repo, roots)
    settings = project / "project.xcworkspace/xcuserdata" / (
        pwd.getpwuid(os.geteuid()).pw_name + ".xcuserdatad"
    ) / "WorkspaceSettings.xcsettings"
    directory(settings.parent, create=True, anchor=owner_snapshot(repo)["worktree"])
    value = {}
    if settings.exists() or settings.is_symlink():
        value = plistlib.loads(policy.read_bytes(settings, private=False))
        if not isinstance(value, dict):
            lease.fail("workspace settings must be a dictionary")
    value.update(DerivedDataLocationStyle="WorkspaceRelativePath",
                 DerivedDataCustomLocation=".build/xcode-gui")
    publish(settings, plistlib.dumps(value))


def retired_resource(state: dict, path: Path, now: dt.datetime) -> dict:
    matches = [r for r in state["resources"] if cleanup.path_within(path, Path(r["identity"]["path"]))]
    if len(matches) != 1:
        lease.fail("target must have one unambiguous registered resource")
    resource = matches[0]
    if resource_status(resource) != "retired":
        lease.fail("resource still has a live/shared owner or release hold")
    if not resource["retired_since"] or policy.timestamp(resource["retired_since"]) > now - dt.timedelta(seconds=RETENTION):
        lease.fail("retirement has not completed seven-day observation retention")
    cleanup.validate_identity(resource["identity"], "registered resource")
    cleanup.validate_identity(resource["parent"], "registered resource parent")
    if resource["kind"] != "derived-data":
        lease.fail("only reconstructable compiler units are eligible; dependency source stays protected")
    for owner in resource["owners"]:
        if cleanup.path_within(path, Path(owner["worktree"]["path"])):
            lease.fail("retired contained outputs belong to worktree removal, not external cleanup")
    cleanup.validate_entry_name(path)
    return resource


def proposal(target: Path, now: dt.datetime | None = None) -> dict:
    now = now or cleanup.now_utc()
    path = state_path()
    data = policy.read_bytes(path, private=True)
    state = read_state(path)
    target = policy.physical_path(str(target))
    resource = retired_resource(state, target, now)
    scanned, _ = cleanup.scan_tree(target, minimum_seconds=RETENTION, current_time=now)
    reference = cleanup.reference_for(path, data)
    return {
        "schema": 1, "scope": cleanup.SCOPE, "targets": [{
            "kind": "retired-generated", "path": str(target), "owner": "plozz/lifecycle",
            "session_id": resource["id"], "worktree": resource["owners"][0]["worktree"],
            "released_at": resource["retired_since"], "release_record": reference,
            "release_evidence": [reference], "observed_at": cleanup.utc(now), **scanned,
        }],
    }


def validate_target(target: dict, manifest: Path, now: dt.datetime, maximum_entries: int):
    policy.exact(target, cleanup.TARGET_KEYS, "retired build target")
    expected = proposal(Path(target["path"]), now)["targets"][0]
    expected["observed_at"] = target["observed_at"]
    observed = policy.timestamp(target["observed_at"])
    if not policy.timestamp(target["released_at"]) <= observed <= now or target != expected:
        lease.fail("retired target provenance, epoch or tree changed since preview")
    if cleanup.path_within(manifest, Path(target["path"])):
        lease.fail("manifest cannot be inside its target")
    _, entries = cleanup.scan_tree(Path(target["path"]), minimum_seconds=RETENTION,
                                   current_time=now, maximum_entries=maximum_entries)
    return target, entries


def validate_target_owner(target: dict, now: dt.datetime) -> None:
    if target["release_record"]["path"] != str(state_path()):
        lease.fail("retirement registry location changed")
    policy.reference(target["release_record"])
    resource = retired_resource(read_state(state_path()), Path(target["path"]), now)
    if resource["id"] != target["session_id"]:
        lease.fail("resource epoch changed")


def legacy_inventory() -> list[dict]:
    """Bounded attribution only. Never adopt an already-absent owner as released."""
    path = lease.paths()["home"] / "Library/Developer/Xcode/DerivedData"
    if not path.exists() and not path.is_symlink():
        return []
    directory(path)
    results = []
    with cleanup.directory_fd(path) as fd:
        names = cleanup.bounded_names(fd, MAX_RESOURCES, "legacy DerivedData inventory limit reached")
    for name in names:
        root = path / name
        if not name.startswith("Plozz-"):
            continue
        try:
            directory(root)
            info = plistlib.loads(policy.read_bytes(root / "info.plist", private=False))
            workspace = Path(policy.text(info.get("WorkspacePath"), "legacy WorkspacePath"))
            if not workspace.is_absolute() or workspace != workspace.resolve(strict=False):
                lease.fail("legacy WorkspacePath has aliases")
            status = "protected: legacy owner absent; no historical generated-root provenance"
            if workspace.exists():
                status = "protected: existing legacy workspace; register at next project generation"
            results.append({"path": str(root), "workspace": str(workspace), "status": status})
        except (OSError, ValueError, TypeError, AttributeError, lease.LeaseError) as exc:
            results.append({"path": str(root), "status": f"blocked: {exc}"})
    return results


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    reg = commands.add_parser("register")
    reg.add_argument("--repo", type=Path, required=True)
    reg.add_argument("--root", nargs=2, action="append", metavar=("KIND", "PATH"), required=True)
    reg.add_argument("--private-child", nargs=2, action="append", default=[],
                     metavar=("CONTAINER", "PATH"))
    settings = commands.add_parser("workspace")
    settings.add_argument("--repo", type=Path, required=True)
    commands.add_parser("reconcile")
    commands.add_parser("status")
    commands.add_parser("legacy")
    preview = commands.add_parser("propose")
    preview.add_argument("--target", type=Path, required=True)
    preview.add_argument("--output", type=Path)
    args = parser.parse_args()
    try:
        if args.command == "register":
            result = register(
                args.repo, [(kind, Path(path)) for kind, path in args.root],
                [(Path(container), Path(child)) for container, child in args.private_child],
            )
        elif args.command == "workspace":
            workspace_settings(args.repo, args.repo / "Plozz.xcodeproj")
            result = {"derived_data": str(args.repo / ".build/xcode-gui")}
        elif args.command == "reconcile":
            with registry() as state:
                result = reconcile(state, cleanup.now_utc())
        elif args.command == "status":
            result = reconcile(read_state(state_path()), cleanup.now_utc())
        elif args.command == "legacy":
            result = legacy_inventory()
        else:
            result = proposal(args.target)
            if args.output:
                if cleanup.path_within(args.output, args.target):
                    lease.fail("proposal cannot be written inside its target")
                cleanup.write_private_new(args.output, cleanup.encode_manifest(result))
                result = {"manifest": str(args.output), "targets": 1}
        print(json.dumps(result, sort_keys=True, indent=2))
        return 0
    except (lease.LeaseError, OSError, ValueError, TypeError, KeyError, subprocess.SubprocessError) as exc:
        print(f"plozz-build-lifecycle: {exc}", file=sys.stderr)
        return 75
