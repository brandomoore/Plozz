#!/usr/bin/env python3
"""Install with bounded retries, structured verification, and retained evidence.

PLOZZ_INSTALL_TIMEOUT: seconds per install (default 180, maximum 600).
PLOZZ_INSTALL_ATTEMPTS: maximum attempts (default 3, maximum 5).
PLOZZ_DEPLOY_INSTALL_DEADLINE: optional explicit overall seconds.

No service resets, pairing changes, device restarts, or cache cleanup.
"""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import plistlib
import runpy
import signal
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
QUERY_TIMEOUT = 45
UNKNOWN = object()


class Interrupted(Exception):
    def __init__(self, signum):
        self.signum = signum


def interrupt(signum, _frame):
    raise Interrupted(signum)


def positive_setting(name, default, maximum):
    value = int(os.environ.get(name, str(default)))
    if not 1 <= value <= maximum:
        raise ValueError(f"{name} must be between 1 and {maximum}")
    return value


class Commands:
    def __init__(self, evidence, lease_fds, deadline=None):
        self.evidence = evidence
        self.lease_fds = lease_fds
        self.deadline = deadline

    @staticmethod
    def terminate(process):
        # Only the process group created for this command belongs to this lane.
        try:
            os.killpg(process.pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            pass
        finally:
            # The parent may exit before a descendant that ignored SIGTERM.
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            process.wait()

    def run(self, name, command, timeout):
        if self.deadline is not None:
            timeout = min(timeout, self.deadline - time.monotonic())
            if timeout <= 0:
                raise TimeoutError("The explicit overall installation deadline expired")
        with (self.evidence / f"{name}.log").open("w") as log:
            process = subprocess.Popen(
                command, stdout=log, stderr=subprocess.STDOUT,
                start_new_session=True, pass_fds=self.lease_fds,
            )
            try:
                return process.wait(timeout=timeout)
            except subprocess.TimeoutExpired:
                self.terminate(process)
                log.write(f"\nCommand exceeded its {timeout:g}s deadline.\n")
                return 124
            except BaseException:
                self.terminate(process)
                raise


class Installer:
    def __init__(self, device, app, evidence, commands, attempts=3, timeout=180, sleep=time.sleep):
        self.device, self.app, self.evidence = device, app, evidence
        self.commands, self.attempts, self.timeout, self.sleep = commands, attempts, timeout, sleep
        with (app / "Info.plist").open("rb") as stream:
            info = plistlib.load(stream)
        values = [info.get(key) for key in ("CFBundleIdentifier", "CFBundleShortVersionString", "CFBundleVersion")]
        if not all(isinstance(value, str) and value for value in values):
            raise ValueError("App bundle is missing its identifier/version/build")
        self.bundle, self.version, self.build = values
        self.target = (self.version, self.build)
        self.confirmed = False
        self.attempt = 0

    def device_command(self, name, arguments, timeout):
        return self.commands.run(name, [
            "xcrun", "devicectl", "device", *arguments,
            "--device", self.device, "--timeout", str(timeout),
            "--json-output", str(self.evidence / f"{name}.json"),
        ], timeout + 5)

    def installed(self, name):
        try:
            status = self.device_command(name, ["info", "apps", "--bundle-id", self.bundle], QUERY_TIMEOUT)
        except TimeoutError:
            return UNKNOWN
        if status:
            return UNKNOWN
        try:
            data = json.loads((self.evidence / f"{name}.json").read_text())
            apps = data["result"]["apps"]
            if not isinstance(apps, list):
                raise ValueError("apps is not an array")
            matches = [app for app in apps if app["bundleIdentifier"] == self.bundle]
            if not matches:
                return None
            if len(matches) != 1:
                raise ValueError("duplicate app identifiers")
            version, build = matches[0]["version"], matches[0]["bundleVersion"]
            if not isinstance(version, str) or not isinstance(build, str):
                raise ValueError("invalid installed version")
            return version, build
        except (OSError, ValueError, KeyError, TypeError) as error:
            print(f"Installed-version reply could not be read ({type(error).__name__}); retaining evidence.", flush=True)
            return UNKNOWN

    def definitive_install_failure(self, name):
        try:
            error = json.loads((self.evidence / f"{name}.json").read_text()).get("error", {})
        except (OSError, ValueError):
            return False

        def has_install_domain(value):
            if isinstance(value, dict):
                if value.get("domain") in {"MIInstallerErrorDomain", "MIInstallErrorDomain", "MobileInstallationErrorDomain"}:
                    return True
                return any(has_install_domain(child) for child in value.values())
            return isinstance(value, list) and any(has_install_domain(child) for child in value)

        return has_install_domain(error)

    def finish(self, outcome, attempts):
        self.confirmed = outcome in {"installed", "verified-after-error", "already-installed"}
        (self.evidence / "receipt.json").write_text(json.dumps({
            "outcome": outcome, "device": self.device, "app": str(self.app),
            "bundleIdentifier": self.bundle, "version": self.version,
            "build": self.build, "attempts": attempts,
        }, indent=2) + "\n")
        return self.confirmed

    def install(self, force=False, launch=True):
        if self.commands.run("signature", ["codesign", "--verify", "--deep", "--strict", str(self.app)], 30):
            print("App signature verification failed; no installation attempted.", flush=True)
            return self.finish("invalid-signature", 0)
        baseline = self.installed("baseline")
        if not force and baseline == self.target:
            print(f"Already installed: {self.version} ({self.build}).", flush=True)
            success = self.finish("already-installed", 0)
        else:
            success = False
            for attempt in range(1, self.attempts + 1):
                self.attempt = attempt
                print(f"Install attempt {attempt}/{self.attempts} (up to {self.timeout}s).", flush=True)
                name = f"install-{attempt}"
                status = self.device_command(name, ["install", "app", str(self.app)], self.timeout)
                current = self.installed(f"verify-{attempt}")
                if status == 0 and (current is UNKNOWN or current == self.target):
                    print(f"Installed {self.version} ({self.build}).", flush=True)
                    if current is UNKNOWN:
                        print("The install completed; the follow-up version query is unavailable.", flush=True)
                    success = self.finish("installed", attempt)
                    break
                # An unchanged build number is not evidence of a --force replacement.
                if current == self.target and baseline is not UNKNOWN and baseline != self.target:
                    print(f"Installed version verified after connection error: {self.version} ({self.build}).", flush=True)
                    success = self.finish("verified-after-error", attempt)
                    break
                if self.definitive_install_failure(name):
                    print("The device rejected the app package; see the retained install error.", flush=True)
                    return self.finish("package-rejected", attempt)
                if attempt < self.attempts:
                    delay = 3 * attempt
                    print(f"Installation not confirmed; retrying after {delay}s without resetting device services.", flush=True)
                    self.sleep(delay)
            if not success:
                print("Installation could not be confirmed after all attempts.", flush=True)
                return self.finish("unconfirmed", self.attempts)
        if launch:
            # Installation is the outcome; retain optional launch errors only in logs.
            try:
                launch_status = self.device_command("launch", ["process", "launch", self.bundle], 30)
            except (OSError, TimeoutError) as error:
                (self.evidence / "launch.log").write_text(f"Optional launch unavailable: {type(error).__name__}.\n")
                launch_status = 124
            if launch_status == 0:
                print("Launch request succeeded.", flush=True)
        return success


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("device")
    parser.add_argument("app", type=Path)
    parser.add_argument("--no-launch", action="store_true")
    parser.add_argument("--force", action="store_true")
    args = parser.parse_args()
    try:
        attempts = positive_setting("PLOZZ_INSTALL_ATTEMPTS", 3, 5)
        timeout = positive_setting("PLOZZ_INSTALL_TIMEOUT", 180, 600)
        deadline = None
        if "PLOZZ_DEPLOY_INSTALL_DEADLINE" in os.environ:
            deadline = time.monotonic() + positive_setting("PLOZZ_DEPLOY_INSTALL_DEADLINE", 900, 7200)
        lease_fds = runpy.run_path(str(ROOT / "tools/run-bounded.py"))["inherited_lease_fds"]()
        base = ROOT / ".build/device-installs"
        base.mkdir(parents=True, exist_ok=True)
        evidence = Path(tempfile.mkdtemp(prefix="install-", dir=base))
        print(f"Installation evidence: {evidence}", flush=True)
        installer = Installer(
            args.device, args.app.resolve(), evidence, Commands(evidence, lease_fds, deadline),
            attempts=attempts, timeout=timeout,
        )
        for signum in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
            signal.signal(signum, interrupt)
        try:
            return 0 if installer.install(force=args.force, launch=not args.no_launch) else 1
        except (Interrupted, KeyboardInterrupt):
            if installer.confirmed:
                return 0
            installer.finish("cancelled", installer.attempt)
            print("Installation cancelled; owned command stopped.", file=sys.stderr)
            return 130
        except (OSError, ValueError, TimeoutError):
            if not installer.confirmed:
                installer.finish("failed", installer.attempt)
            raise
    except (OSError, ValueError, TimeoutError) as error:
        print(f"Installation failed: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
