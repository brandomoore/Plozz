"""Content-addressed evidence for a complete, unchanged extraction build."""

from __future__ import annotations

import contextlib
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
from typing import Iterator


class FreshnessError(RuntimeError):
    pass


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def canonical(value: object) -> bytes:
    return json.dumps(value, sort_keys=True, separators=(",", ":")).encode()


def read_stable(path: Path) -> bytes:
    before = path.stat()
    data = path.read_bytes()
    after = path.stat()
    if (before.st_ino, before.st_size, before.st_mtime_ns) != (
        after.st_ino, after.st_size, after.st_mtime_ns
    ):
        raise FreshnessError(f"Input changed while being fingerprinted: {path.name}")
    return data


def checkout_environment() -> dict[str, str]:
    env = dict(os.environ)
    # Git exports repository selectors into hooks. They override cwd/-C and
    # otherwise make a dependency lookup inspect the parent repository instead.
    for name in (
        "GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_COMMON_DIR", "GIT_PREFIX",
        "GIT_OBJECT_DIRECTORY", "GIT_ALTERNATE_OBJECT_DIRECTORIES",
        "GIT_IMPLICIT_WORK_TREE", "GIT_GRAFT_FILE", "GIT_NAMESPACE",
    ):
        env.pop(name, None)
    return env


def command(repo: Path, *args: str) -> bytes:
    return subprocess.check_output(args, cwd=repo, env=checkout_environment(),
                                   stderr=subprocess.PIPE, timeout=30)


def source_fingerprint(repo: Path, *, exclude: set[str] | None = None) -> str:
    """Hash actual bytes, including dirty/untracked sources and local build config.

    Only digests leave this function; local xcconfigs and generated projects may
    contain credentials. Commit IDs and mtimes are not substitutes for content.
    """
    excluded = exclude or set()
    names = set(command(repo, "git", "ls-files", "--cached", "--others",
                        "--exclude-standard", "-z").decode().split("\0")) - {""}
    names.update(str(path.relative_to(repo)) for path in (repo / "Config").rglob("*.xcconfig"))
    project = repo / "Plozz.xcodeproj"
    names.update(str(path.relative_to(repo)) for path in project.rglob("*.xcscheme"))
    names.update({
        "Plozz.xcodeproj/project.pbxproj",
        "Plozz.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved",
    })
    result = hashlib.sha256()
    for name in sorted(names - excluded):
        path = repo / name
        result.update(canonical(name))
        if path.is_symlink():
            result.update(canonical({"symlink": os.readlink(path)}))
        if path.is_file():
            result.update(canonical({"mode": path.stat().st_mode & 0o777}))
            data = read_stable(path)
            if name == "Plozz.xcodeproj/project.pbxproj":
                # Generation changes only this version stamp between ordinary
                # builds. It is not an input to Swift string extraction.
                data = re.sub(rb"(?m)^(\s*CURRENT_PROJECT_VERSION = )[^;\r\n]*;",
                              rb"\1<generated>;", data)
            result.update(b"file\0" + digest(data).encode())
        elif not path.exists():
            result.update(b"missing\0")
        else:
            raise FreshnessError(f"Unsupported source input: {name}")
    return result.hexdigest()


def environment_fingerprint() -> str:
    names = {
        "PATH", "DEVELOPER_DIR", "TOOLCHAINS", "SDKROOT", "XCODE_XCCONFIG_FILE",
        "CC", "CXX", "LD", "CPATH", "LIBRARY_PATH", "CFLAGS", "CXXFLAGS",
        "LDFLAGS", "LANG", "LC_ALL", "XDG_CONFIG_HOME",
    }
    prefixes = ("PLOZZ_", "SWIFT_", "CLANG_", "OTHER_", "DYLD_")
    values = {key: value for key, value in os.environ.items()
              if (key in names or key.startswith(prefixes))
              and key != "PLOZZ_BUILD_LEASE_WRAPPED"}
    override = os.environ.get("XCODE_XCCONFIG_FILE")
    if override:
        values["XCODE_XCCONFIG_CONTENT_SHA256"] = digest(read_stable(Path(override)))
    return digest(canonical(values))


def toolchain_fingerprint(repo: Path) -> str:
    facts = [command(repo, "xcodebuild", "-version")]
    for sdk in ("iphonesimulator", "appletvsimulator"):
        facts.append(command(repo, "xcrun", "--sdk", sdk, "--show-sdk-path"))
        facts.append(command(repo, "xcrun", "--sdk", sdk, "--show-sdk-build-version"))
    for tool in ("swiftc", "xcstringstool"):
        path = Path(command(repo, "xcrun", "--find", tool).decode().strip())
        st = path.stat()
        facts.append(canonical((str(path), st.st_ino, st.st_size, st.st_mtime_ns)))
    return digest(b"\0".join(facts))


def package_workspace_fingerprint(repo: Path, workspace: Path) -> str:
    """Reject modified checkouts even when Package.resolved did not change."""
    facts = []
    checkouts = workspace / "checkouts"
    for path in sorted(checkouts.iterdir() if checkouts.exists() else []):
        if not path.is_dir():
            raise FreshnessError("Unexpected package checkout entry")
        status = command(path, "git", "status", "--porcelain", "--untracked-files=all")
        if status:
            raise FreshnessError(f"Modified localization package checkout: {path.name}")
        facts.append((path.name, command(path, "git", "rev-parse", "HEAD").decode().strip()))
    state = workspace / "workspace-state.json"
    state_digest = None
    if state.exists():
        try:
            value = json.loads(read_stable(state))
        except (json.JSONDecodeError, UnicodeDecodeError) as error:
            raise FreshnessError("Invalid package workspace state JSON") from error
        if not isinstance(value, dict):
            raise FreshnessError("Package workspace state must be a JSON object")
        workspace_object = value.get("object")
        if isinstance(workspace_object, dict) and isinstance(workspace_object.get("artifacts"), list):
            # SwiftPM reorders this inventory when switching platforms; its values still matter.
            workspace_object["artifacts"] = sorted(workspace_object["artifacts"], key=canonical)
        state_digest = digest(canonical(value))
    return digest(canonical({
        "path": str(workspace.resolve()),
        "checkouts": facts,
        "state": state_digest,
    }))


def extraction_files(derived: Path, arch: str) -> list[Path]:
    intermediates = derived / "Build/Intermediates.noindex"
    return sorted(path for path in intermediates.rglob("*.stringsdata") if path.parent.name == arch)


def output_fingerprint(derived: Path, arch: str) -> str | None:
    files = extraction_files(derived, arch)
    if not files:
        return None
    return digest(canonical([
        (str(path.relative_to(derived)), digest(read_stable(path))) for path in files
    ]))


@contextlib.contextmanager
def extraction_lock(repo: Path) -> Iterator[None]:
    path = repo / ".build/l10n-extraction.lock"
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a") as handle:
        try:
            fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            print("Waiting for this worktree's localization extraction writer.", flush=True)
            fcntl.flock(handle, fcntl.LOCK_EX)
        yield


class ExtractionReceipt:
    def __init__(self, repo: Path, derived: Path, workspace: Path, arch: str):
        self.repo, self.derived, self.workspace, self.arch = repo, derived, workspace, arch
        self.path = derived / ".plozz-full-extraction.json"
        self.catalog = repo / "App/Resources/Localizable.xcstrings"
        self.toolchain = toolchain_fingerprint(repo)

    def inputs(self) -> str:
        return digest(canonical({
            "source": source_fingerprint(self.repo, exclude={str(self.catalog.relative_to(self.repo))}),
            "environment": environment_fingerprint(),
            "toolchain": self.toolchain,
            "arch": self.arch,
            "derived": str(self.derived.resolve()),
        }))

    def invalidate(self) -> None:
        self.path.unlink(missing_ok=True)

    def matches(self, inputs: str) -> bool:
        try:
            recorded = json.loads(self.path.read_text())
            output = output_fingerprint(self.derived, self.arch)
            return (
                isinstance(recorded, dict) and recorded.get("schemaVersion") == 1
                and recorded.get("platforms") == ["ios", "tvos"]
                and recorded.get("inputs") == inputs
                and recorded.get("catalog") == digest(read_stable(self.catalog))
                and recorded.get("packages") == package_workspace_fingerprint(self.repo, self.workspace)
                and output is not None and recorded.get("output") == output
            )
        except (OSError, ValueError, TypeError, FreshnessError, subprocess.SubprocessError):
            return False

    def record(self, inputs: str) -> None:
        if inputs != self.inputs() or self.toolchain != toolchain_fingerprint(self.repo):
            raise FreshnessError("Sources or build configuration changed during extraction; rerun it.")
        output = output_fingerprint(self.derived, self.arch)
        if output is None:
            raise FreshnessError("No extraction output to record")
        value = {
            "schemaVersion": 1, "platforms": ["ios", "tvos"], "inputs": inputs,
            "catalog": digest(read_stable(self.catalog)), "output": output,
            "packages": package_workspace_fingerprint(self.repo, self.workspace),
        }
        self.derived.mkdir(parents=True, exist_ok=True)
        fd, temporary = tempfile.mkstemp(prefix=".extraction-", dir=self.derived)
        try:
            with os.fdopen(fd, "wb") as stream:
                stream.write(canonical(value) + b"\n")
                stream.flush()
                os.fsync(stream.fileno())
            os.replace(temporary, self.path)
        finally:
            Path(temporary).unlink(missing_ok=True)
