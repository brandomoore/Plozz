#!/usr/bin/env python3
"""Serialize local main landings across linked worktrees; retain the normal hook."""

from contextlib import contextmanager
import fcntl
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time


@contextmanager
def landing(root, *, timeout=7200):
    common = subprocess.check_output(
        ["git", "rev-parse", "--git-common-dir"], cwd=root, text=True, timeout=30
    ).strip()
    path = (root / common).resolve() / "plozz-main-landing.lock"
    inherited = os.environ.get("PLOZZ_MAIN_LANDING_FD")
    handle = None
    if inherited is not None:
        fd = int(inherited)
        if fd < 3 or (os.fstat(fd).st_dev, os.fstat(fd).st_ino) != (
            path.stat().st_dev, path.stat().st_ino
        ):
            raise RuntimeError("Invalid inherited main landing lock")
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    else:
        handle = path.open("a")
        fd = handle.fileno()
        deadline = time.monotonic() + timeout
        announced = False
        try:
            while True:
                try:
                    fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                    break
                except BlockingIOError:
                    if not announced:
                        print("Waiting for the existing local main landing; no builds started.", flush=True)
                        announced = True
                    if time.monotonic() >= deadline:
                        raise TimeoutError("Main landing wait exceeded its deadline")
                    time.sleep(0.25)
        except BaseException:
            handle.close()
            raise
        os.environ["PLOZZ_MAIN_LANDING_FD"] = str(fd)
    try:
        yield fd
    finally:
        if handle is not None:
            os.environ.pop("PLOZZ_MAIN_LANDING_FD", None)
            handle.close()


def pre_push(root, updates):
    rows = [line.split() for line in updates.splitlines()]
    if any(len(row) != 4 for row in rows):
        raise RuntimeError("Invalid pre-push ref update")
    if not any(row[2] == "refs/heads/main" for row in rows):
        return
    with landing(root) as fd:
        lease_names = ("APPLE_BUILD_LEASE_LOCK_FD", "APPLE_BUILD_LEASE_PROOF_FD")
        fds = (fd, *(int(os.environ[name]) for name in lease_names if name in os.environ))
        env = dict(os.environ, GIT_CONFIG_PARAMETERS="'safe.bareRepository=all'")
        output = root / ".build"
        output.mkdir(exist_ok=True)
        with tempfile.NamedTemporaryFile(prefix="main-l10n-", suffix=".json", dir=output) as delta:
            print("▸ Pre-main localization gate", flush=True)
            for command in (
                ["tools/l10n-guard.sh"],
                [sys.executable, "tools/l10n-sync.py", "--check", "--quiet", "--reuse-if-unchanged"],
                [sys.executable, "tools/l10n-export-source.py", delta.name,
                 "--missing-for", "nl", "--check-snapshot"],
            ):
                subprocess.run(command, cwd=root, env=env, pass_fds=fds, check=True, timeout=1200)
            print("✓ Pre-main localization gate passed.", flush=True)


if __name__ == "__main__":
    try:
        root = Path(subprocess.check_output(
            ["git", "rev-parse", "--show-toplevel"], text=True, timeout=30).strip())
        pre_push(root, sys.stdin.read())
    except subprocess.CalledProcessError as error:
        print(f"main-landing: {error}", file=sys.stderr)
        raise SystemExit(error.returncode if error.returncode > 0 else 1)
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
        print(f"main-landing: {error}", file=sys.stderr)
        raise SystemExit(1)
