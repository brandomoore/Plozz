#!/usr/bin/env python3
"""Workspace-local CI storage and conservative Xcode cache compatibility keys."""

from __future__ import annotations

import argparse
from contextlib import contextmanager
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import stat
import subprocess
import time


LANES = ("app-build", "package-tests", "hosted-focus")
SCHEMA = "plozz-ci-v2-trusted-main"
BUILD_PARTS = (
    "DerivedData/Build",
    "DerivedData/ModuleCache.noindex",
    "DerivedData/SDKStatCaches.noindex",
    "DerivedData/CompilationCache.noindex",
    "SourcePackages",
    "source-timestamps.json",
)
SOURCE_DIRECTORIES = ("Sources", "Tests", "App", "TopShelf", "Config")
SOURCE_FILES = ("Package.swift", "Package.resolved", "project.yml")
CONFIG_INPUTS = (
    "Package.swift",
    "Package.resolved",
    "project.yml",
    ".github/workflows/ci.yml",
    ".github/actions/ci-prepare/action.yml",
    ".github/actions/ci-save/action.yml",
    "tools/ci-cache.py",
    "tools/generate-project.sh",
    "tools/run-tests.sh",
    "tools/run-focus-tests.sh",
    "tools/run-bounded.py",
    "tools/select-ci-tvos-simulator.py",
    "tools/lib/swift-package-storage.sh",
)


def digest(values: dict[str, str]) -> str:
    return hashlib.sha256(
        json.dumps(values, sort_keys=True, separators=(",", ":")).encode()
    ).hexdigest()


def lane_root(lane: str) -> Path:
    if lane not in LANES:
        raise ValueError(f"Unknown CI lane: {lane}")
    return Path(".build/ci") / lane


def build_paths(lane: str) -> list[str]:
    return [str(lane_root(lane) / part) for part in BUILD_PARTS]


def environment(root: Path, lane: str) -> dict[str, str]:
    private = root / lane_root(lane)
    derived = str(private / "DerivedData")
    packages = str(private / "SourcePackages")
    return {
        "PLOZZ_DERIVED_DATA": derived,
        "PLOZZ_FOCUS_DERIVED_DATA": derived,
        "PLOZZ_CLONED_SOURCE_PACKAGES": packages,
        "PLOZZ_FOCUS_PACKAGES": packages,
        "PLOZZ_PACKAGE_CACHE_PATH": str(root / ".build/ci/swiftpm-cache"),
        "PLOZZ_LOG_DIR": str(root / ".build/ci-logs" / lane),
        "TMPDIR": str(root / ".build/ci-scratch" / lane),
    }


def tracked_inputs(root: Path) -> set[str]:
    paths = subprocess.check_output(
        ["git", "ls-files", "-z", "--cached", "--", *SOURCE_DIRECTORIES, *SOURCE_FILES],
        cwd=root,
    )
    return {os.fsdecode(path) for path in paths.split(b"\0") if path}


def relative_parts(name: str) -> tuple[str, ...]:
    if not isinstance(name, str) or "\0" in name:
        raise ValueError("Invalid workspace-relative path")
    path = PurePosixPath(name)
    if path.is_absolute() or not path.parts or any(part in ("", ".", "..") for part in name.split("/")):
        raise ValueError("Invalid workspace-relative path")
    return path.parts


def is_source_input(name: str) -> bool:
    try:
        parts = relative_parts(name)
    except ValueError:
        return False
    return name in SOURCE_FILES or (len(parts) > 1 and parts[0] in SOURCE_DIRECTORIES)


@contextmanager
def workspace_file(root: Path, name: str, *, write: bool = False):
    """Open through directory descriptors, never following links or `..`."""
    parts = relative_parts(name)
    directory_flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW
    directory = os.open(root, directory_flags)
    descriptor = None
    try:
        for part in parts[:-1]:
            child = os.open(part, directory_flags, dir_fd=directory)
            os.close(directory)
            directory = child
        flags = os.O_WRONLY | os.O_CREAT if write else os.O_RDONLY
        descriptor = os.open(
            parts[-1], flags | os.O_NOFOLLOW | os.O_NONBLOCK, 0o600, dir_fd=directory
        )
        info = os.fstat(descriptor)
        # A hard link could alter a file outside the workspace without any
        # symlink in its path. Git checkouts do not need multiply-linked files.
        if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1:
            raise ValueError("Expected a single-link regular workspace file")
        yield descriptor
    finally:
        if descriptor is not None:
            os.close(descriptor)
        os.close(directory)


def source_identity(descriptor: int) -> dict[str, int | str] | None:
    before = os.fstat(descriptor)
    checksum = hashlib.sha256()
    while chunk := os.read(descriptor, 1024 * 1024):
        checksum.update(chunk)
    after = os.fstat(descriptor)
    if (before.st_size, before.st_mtime_ns, before.st_ctime_ns, before.st_mode) != (
        after.st_size, after.st_mtime_ns, after.st_ctime_ns, after.st_mode
    ):
        return None
    return {
        "sha256": checksum.hexdigest(),
        "size": after.st_size,
        "mode": stat.S_IMODE(after.st_mode),
        "mtime_ns": after.st_mtime_ns,
    }


def timestamp_manifest(lane: str) -> str:
    return str(lane_root(lane) / "source-timestamps.json")


def record_source_timestamps(root: Path, lane: str) -> int:
    files = {}
    for name in sorted(tracked_inputs(root)):
        if not is_source_input(name):
            continue
        try:
            with workspace_file(root, name) as descriptor:
                identity = source_identity(descriptor)
            if identity is not None:
                files[name] = identity
        except (OSError, ValueError):
            # Deleted inputs and links must not become timestamp candidates.
            continue
    with workspace_file(root, timestamp_manifest(lane), write=True) as descriptor:
        os.ftruncate(descriptor, 0)
        with os.fdopen(os.dup(descriptor), "w") as stream:
            json.dump({"version": 1, "files": files}, stream, sort_keys=True)
    return len(files)


def restore_source_timestamps(root: Path, lane: str) -> int:
    try:
        with workspace_file(root, timestamp_manifest(lane)) as descriptor:
            with os.fdopen(os.dup(descriptor)) as stream:
                snapshot = json.load(stream)
    except (OSError, ValueError):
        return 0
    if not isinstance(snapshot, dict) or snapshot.get("version") != 1:
        return 0
    files = snapshot.get("files")
    if not isinstance(files, dict):
        return 0

    tracked = tracked_inputs(root)
    restored = 0
    now = time.time_ns()
    for name, saved in files.items():
        if name not in tracked or not is_source_input(name) or not isinstance(saved, dict):
            continue
        mtime = saved.get("mtime_ns")
        if type(mtime) is not int or not 0 <= mtime <= now:
            continue
        try:
            with workspace_file(root, name) as descriptor:
                original = os.fstat(descriptor)
                current = source_identity(descriptor)
                if current is None or any(
                    current[key] != saved.get(key) for key in ("sha256", "size", "mode")
                ):
                    continue
                os.utime(descriptor, ns=(original.st_atime_ns, mtime))
                restored += 1
        except (OSError, ValueError):
            continue
    return restored


def normalized_project(data: str) -> str:
    # The generator bakes these on every run. Do not force a cold dependency
    # compile at midnight or after a commit-count bump. Xcode still sees the
    # freshly generated, unmodified project and rebuilds affected products.
    return re.sub(
        r"(?m)^(\s*(?:CURRENT_PROJECT_VERSION|MARKETING_VERSION) = )[^;\n]+;",
        r"\1<generated-version>;",
        data,
    )


def workspace_text(root: Path, name: str) -> str:
    with workspace_file(root, name) as descriptor:
        with os.fdopen(os.dup(descriptor), encoding="utf-8") as stream:
            return stream.read()


def metadata_files(root: Path, directory: str):
    """Enumerate metadata beneath no-follow directory descriptors."""
    directory_flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW
    descriptor = os.open(root, directory_flags)

    def walk(parent, prefix):
        with os.scandir(parent) as entries:
            for entry in sorted(entries, key=lambda item: item.name):
                name = f"{prefix}/{entry.name}"
                if entry.is_symlink():
                    raise ValueError(f"Symlinked cache-key input: {name}")
                if entry.is_dir(follow_symlinks=False):
                    child = os.open(entry.name, directory_flags, dir_fd=parent)
                    try:
                        yield from walk(child, name)
                    finally:
                        os.close(child)
                elif entry.is_file(follow_symlinks=False):
                    yield name

    try:
        for part in relative_parts(directory):
            try:
                child = os.open(part, directory_flags, dir_fd=descriptor)
            except FileNotFoundError:
                return
            os.close(descriptor)
            descriptor = child
        yield from walk(descriptor, directory)
    finally:
        os.close(descriptor)


def input_fingerprints(root: Path) -> tuple[str, str]:
    packages = {}
    for name in ("Package.swift", "Package.resolved"):
        packages[name] = workspace_text(root, name)
    # A missing/broken lock is not a reusable dependency graph.
    lock = json.loads(packages["Package.resolved"])
    if not lock.get("pins"):
        raise ValueError("Package.resolved has no pins")

    inputs = {name: workspace_text(root, name) for name in CONFIG_INPUTS}
    for name in metadata_files(root, "Config"):
        if not name.endswith(".xcconfig"):
            continue
        if PurePosixPath(name).name == "Secrets.local.xcconfig":
            raise ValueError("CI cache must not contain a build with local secrets")
        inputs[name] = workspace_text(root, name)
    inputs["Plozz.xcodeproj/project.pbxproj"] = normalized_project(
        workspace_text(root, "Plozz.xcodeproj/project.pbxproj")
    )
    for name in metadata_files(root, "Plozz.xcodeproj"):
        if name.endswith(".xcscheme") or PurePosixPath(name).name == "contents.xcworkspacedata":
            inputs[name] = workspace_text(root, name)
    return digest(packages), digest(inputs)


def cache_keys(
    lane: str, toolchain: dict[str, str], packages: str, configuration: str, revision: str
) -> dict[str, str]:
    lane_root(lane)
    if not re.fullmatch(r"[0-9a-f]{40}", revision):
        raise ValueError("Expected the checked-out 40-character Git revision")
    compatibility = digest(toolchain)
    prefix = f"{SCHEMA}-{compatibility}"
    build_prefix = f"{prefix}-{lane}-{configuration}-"
    return {
        "package-key": f"{prefix}-packages-{packages}",
        "build-prefix": build_prefix,
        "build-key": f"{build_prefix}{revision}",
    }


def command(*args: str) -> str:
    return subprocess.check_output(args, text=True).strip()


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("operation", choices=("configure", "keys", "record", "restore"))
    parser.add_argument("lane", choices=LANES)
    args = parser.parse_args()
    root = Path.cwd().resolve()
    if os.environ.get("GITHUB_ACTIONS") != "true":
        parser.error("This helper is only for GitHub-hosted CI")
    if root != Path(os.environ["GITHUB_WORKSPACE"]).resolve():
        parser.error("Run from the checked-out GitHub workspace")
    if args.operation == "record":
        count = record_source_timestamps(root, args.lane)
        print(f"Recorded content-verified timestamps for {count} tracked build inputs.")
        return
    if args.operation == "restore":
        count = restore_source_timestamps(root, args.lane)
        print(f"Restored timestamps for {count} unchanged tracked build inputs; all others stay fresh.")
        return
    if args.operation == "configure":
        for name, value in environment(root, args.lane).items():
            path = Path(value)
            if not path.resolve().is_relative_to(root):
                parser.error(f"CI storage escapes the workspace: {path}")
            path.mkdir(parents=True, exist_ok=True)
            print(f"{name}={value}")
        return

    packages, configuration = input_fingerprints(root)
    toolchain = {
        "workspace": str(root),
        "xcode": command("xcodebuild", "-version"),
        "developer": command("xcode-select", "-p"),
        "sdk": command("xcrun", "--sdk", "appletvsimulator", "--show-sdk-version"),
        "sdk-build": command("xcrun", "--sdk", "appletvsimulator", "--show-sdk-build-version"),
        "sdk-path": command("xcrun", "--sdk", "appletvsimulator", "--show-sdk-path"),
        "host-arch": command("uname", "-m"),
        "os-build": command("sw_vers", "-buildVersion"),
        "xcodegen": command("xcodegen", "--version"),
    }
    revision = command("git", "rev-parse", "HEAD")
    for name, value in cache_keys(args.lane, toolchain, packages, configuration, revision).items():
        print(f"{name}={value}")
    print("build-paths<<PLOZZ_CI_PATHS")
    print("\n".join(build_paths(args.lane)))
    print("PLOZZ_CI_PATHS")


if __name__ == "__main__":
    main()
