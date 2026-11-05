#!/usr/bin/env python3
"""Isolated Blu-ray navigation experiment; never packages or installs Plozz."""
from __future__ import annotations

import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import platform
import runpy
import shlex
import signal
import subprocess
import sys
import tarfile
import uuid

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent
WORK = ROOT / ".build/disc-menu-lab"


def verify_archive(path: Path, specification: dict) -> None:
    algorithm = "sha256" if "sha256" in specification else "sha512"
    with path.open("rb") as source:
        digest = hashlib.file_digest(source, algorithm).hexdigest()
    if digest != specification[algorithm]:
        raise ValueError(f"{path.name}: {algorithm} mismatch; refusing extraction")


class Lab:
    def __init__(self) -> None:
        lease = runpy.run_path(str(ROOT / "tools/run-bounded.py"))
        self.lease_fds = lease["inherited_lease_fds"]()
        if not self.lease_fds:
            os.execv(str(ROOT / "tools/with-apple-build-lease.sh"), [
                "with-apple-build-lease.sh", "plozz/disc-menu-lab", "--",
                sys.executable, str(Path(sys.argv[0]).resolve()), *sys.argv[1:],
            ])
        WORK.mkdir(parents=True, exist_ok=True)
        self.lock = (WORK / "lab.lock").open("a")
        try:
            fcntl.flock(self.lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as error:
            raise RuntimeError("Another disc-menu lab command owns this build directory") from error
        self.run_dir = WORK / "runs" / uuid.uuid4().hex
        self.run_dir.mkdir(parents=True)
        self.environment = dict(os.environ)
        self.environment["GIT_CONFIG_PARAMETERS"] = "'safe.bareRepository=all'"
        self.commands: list[dict] = []
        print(f"Evidence: {self.run_dir}", flush=True)

    def run(self, name: str, arguments: list[str | Path], *, cwd: Path = ROOT,
            timeout: int = 300) -> None:
        arguments = [str(argument) for argument in arguments]
        log = self.run_dir / f"{len(self.commands):02d}-{name}.log"
        self.commands.append({"name": name, "argv": arguments, "log": log.name})
        (self.run_dir / "commands.json").write_text(json.dumps(self.commands, indent=2) + "\n")
        print(name, flush=True)
        with log.open("w") as output:
            process = subprocess.Popen(
                arguments,
                cwd=cwd, env=self.environment, stdin=subprocess.DEVNULL,
                stdout=output, stderr=subprocess.STDOUT,
                pass_fds=self.lease_fds, start_new_session=True,
            )
            try:
                status = process.wait(timeout=timeout)
            except subprocess.TimeoutExpired as error:
                raise RuntimeError(f"{name} exceeded {timeout}s; evidence: {log}") from error
            finally:
                # The command and its children are owned by this invocation.
                # Also reap them on cancellation, not only on a deadline.
                try:
                    os.killpg(process.pid, signal.SIGTERM)
                except ProcessLookupError:
                    pass
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    os.killpg(process.pid, signal.SIGKILL)
                    process.wait()
        if status:
            print("\n".join(log.read_text(errors="replace").splitlines()[-65:]), file=sys.stderr)
            raise RuntimeError(f"{name} exited {status}; evidence: {log}")

    def dependencies(self, *, zero: bool = False, bdj: bool = False) -> dict[str, Path]:
        if platform.system() != "Darwin" or platform.machine() != "arm64":
            raise RuntimeError("The pinned host JDK currently targets Apple Silicon macOS only")
        specifications = json.loads((HERE / "dependencies.json").read_text())
        dependencies = WORK / "dependencies"
        dependencies.mkdir(parents=True, exist_ok=True)
        resolved = {}
        for name, specification in specifications.items():
            if name == "menu-fonts" and not bdj:
                continue
            if name in ("zero-source", "libffi-source") and not zero:
                continue
            fingerprint = specification.get("sha256", specification.get("sha512"))[:16]
            destination = dependencies / f"{name}-{fingerprint}"
            archive = dependencies / f"{name}-{fingerprint}.archive"
            if not archive.exists():
                partial = archive.with_suffix(".partial")
                self.run(f"download-{name}", [
                    "curl", "--fail", "--location", "--silent", "--show-error",
                    "--max-time", "300", "--output", partial, specification["url"],
                ], timeout=310)
                verify_archive(partial, specification)
                partial.replace(archive)
            verify_archive(archive, specification)
            if not destination.exists():
                staging = dependencies / f"{name}-{uuid.uuid4().hex}.extracting"
                staging.mkdir()
                with tarfile.open(archive) as source:
                    source.extractall(staging, filter="data")
                if not (staging / specification["root"]).is_dir():
                    raise ValueError(f"{name}: expected archive root is missing")
                staging.rename(destination)
            resolved[name] = destination / specification["root"]
        java_home = resolved["host-jdk"] / "Contents/Home"
        self.environment["JAVA_HOME"] = str(java_home)
        self.environment["PATH"] = os.pathsep.join([
            str(java_home / "bin"), str(resolved["ant"] / "bin"),
            self.environment.get("PATH", ""),
        ])
        self.run("host-java-version", [java_home / "bin/java", "-version"])
        return resolved

    def host(self, dependencies: dict[str, Path]) -> Path:
        # Upstream enables disc networking unconditionally. Only this owned
        # experiment source is changed; never run third-party Xlets in the lab.
        source = dependencies["libbluray"] / "src/libbluray/bdj/java/org/videolan/Libbluray.java"
        original = 'System.setProperty("bluray.network.connected", "YES");'
        replacement = 'System.setProperty("bluray.network.connected", "NO");'
        text = source.read_text()
        if text.count(original) == 1:
            source.write_text(text.replace(original, replacement))
        elif text.count(replacement) != 1:
            raise RuntimeError("Pinned libbluray networking patch no longer matches")
        build = WORK / "host-libbluray"
        if not (build / "build.ninja").exists():
            self.run("configure-host-libbluray", [
                "meson", "setup", build, dependencies["libbluray"],
                "-Dbdj_jar=enabled", "-Denable_tools=true", "-Denable_devtools=true",
                f"-Djdk_home={self.environment['JAVA_HOME']}",
                "-Ddefault_library=static",
            ])
        self.run("build-host-libbluray", ["meson", "compile", "-C", build, "-j", "4"],
                 timeout=600)
        return build

    def navigate(self, dependencies: dict[str, Path], build: Path) -> None:
        import fixture
        clips = self.run_dir / "clips"
        self.run("generate-original-clips", [
            sys.executable, ROOT / "tools/generate-bdmv-test-fixture.py", "--output", clips,
        ], timeout=400)
        disc = self.run_dir / "disc"
        fixture.create(disc, clips / "BDMV/STREAM")
        java = Path(self.environment["JAVA_HOME"]) / "bin"
        jars = build / "src/libbluray/bdj"
        classes = self.run_dir / "classes"
        classes.mkdir()
        self.run("compile-original-xlet", [
            java / "javac", "--release", "8", "-classpath",
            jars / "libbluray-j2se-1.5.0.jar", "-d", classes, HERE / "MenuXlet.java",
        ])
        self.run("package-original-xlet", [
            java / "jar", "--create", "--file", disc / "BDMV/JAR/00000.jar",
            "-C", classes, ".",
        ])
        self.environment["PKG_CONFIG_PATH"] = str(build / "meson-uninstalled")
        self.run("host-link-flags", [
            "pkg-config", "--cflags", "--libs", "libbluray-uninstalled",
        ])
        # pkg-config's bounded output is the argument source, not a shell command.
        flags_file = self.run_dir / self.commands[-1]["log"]
        flags = shlex.split(flags_file.read_text())
        executable = self.run_dir / "navigation"
        self.run("compile-navigation-harness", [
            "clang", "-std=c11", "-Wall", "-Wextra", "-Werror",
            HERE / "navigation.c", "-o", executable, *flags,
        ])
        self.environment["LIBBLURAY_CP"] = str(jars) + "/"
        self.environment["JAVA_TOOL_OPTIONS"] = (
            "-Xint -Djava.security.manager=allow "
            f"-XX:ErrorFile={self.run_dir}/hs_err_pid%p.log")
        self.run("navigate-original-disc", [
            executable, disc, self.environment["JAVA_HOME"], self.run_dir,
        ], cwd=self.run_dir, timeout=90)
        for episode in (1, 2):
            self.run(f"decode-episode-{episode}", [
                "ffmpeg", "-hide_banner", "-loglevel", "error", "-xerror",
                "-i", self.run_dir / f"episode-{episode}.m2ts",
                "-frames:v", "1", self.run_dir / f"episode-{episode}.png",
            ])
            self.run(f"verify-episode-{episode}-color", [
                "ffmpeg", "-hide_banner", "-loglevel", "error", "-i",
                self.run_dir / f"episode-{episode}.png", "-vf", "scale=1:1",
                "-pix_fmt", "rgb24", "-f", "rawvideo",
                self.run_dir / f"episode-{episode}.rgb",
            ])
            color = (self.run_dir / f"episode-{episode}.rgb").read_bytes()
            expected = 0 if episode == 1 else 2
            if len(color) != 3 or color[expected] < 200 or any(
                channel > 50 for index, channel in enumerate(color) if index != expected
            ):
                raise RuntimeError(f"Episode {episode} decoded the wrong original test color: {color!r}")
        for menu in ("first", "second"):
            self.run(f"export-menu-{menu}", [
                "ffmpeg", "-hide_banner", "-loglevel", "error", "-i",
                self.run_dir / f"menu-{menu}.ppm", "-frames:v", "1",
                self.run_dir / f"menu-{menu}.png",
            ])
        (self.run_dir / "result.json").write_text(json.dumps({
            "host_navigation": "pass",
            "runtime": "Temurin HotSpot 21 with -Xint; NOT Zero or tvOS",
            "libbluray": "1.5.0 with disc networking disabled",
            "playlists": [1, 2],
            "physical_device": "not tested",
        }, indent=2) + "\n")

    def zero_probe(self, dependencies: dict[str, Path]) -> None:
        self.run("tvos-sdk", ["xcrun", "--sdk", "appletvos", "--show-sdk-path"])
        sdk = (self.run_dir / self.commands[-1]["log"]).read_text().strip()
        failures = []
        for target in ("aarch64-apple-tvos", "aarch64-apple-darwin"):
            build = self.run_dir / target
            build.mkdir()
            try:
                self.run(f"configure-zero-{target}", [
                    "bash", dependencies["zero-source"] / "configure",
                    f"--openjdk-target={target}", "--with-jvm-variants=zero",
                    f"--with-boot-jdk={self.environment['JAVA_HOME']}",
                    f"--with-sysroot={sdk}",
                    "--with-extra-cflags=-target arm64-apple-tvos17.0",
                    "--with-extra-cxxflags=-target arm64-apple-tvos17.0",
                    "--with-extra-ldflags=-target arm64-apple-tvos17.0",
                    "--disable-warnings-as-errors",
                ], cwd=build, timeout=180)
                self.run(f"compile-zero-{target}", ["make", "hotspot", "JOBS=4"],
                         cwd=build, timeout=600)
            except RuntimeError as error:
                failures.append(str(error))
                continue
            raise RuntimeError("Zero compiled, but execution/no-JIT validation is still required")
        (self.run_dir / "zero-result.json").write_text(json.dumps({
            "status": "blocked", "attempts": failures,
            "source": dependencies["zero-source"].name,
        }, indent=2) + "\n")
        raise RuntimeError("Both tvOS Zero build probes failed; retained zero-result.json")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=[
        "bootstrap", "host", "navigate", "zero-probe", "tvos-build", "tvos-runtime",
        "tvos-smoke", "tvos-bdj", "tvos-bdj-device-build",
    ])
    args = parser.parse_args()
    def interrupted(signum, frame):
        raise InterruptedError(f"Disc-menu lab interrupted by signal {signum}")

    signal.signal(signal.SIGTERM, interrupted)
    try:
        lab = Lab()
        dependencies = lab.dependencies(zero=args.command in (
            "zero-probe", "tvos-build", "tvos-runtime", "tvos-smoke", "tvos-bdj",
            "tvos-bdj-device-build"),
            bdj=args.command in ("tvos-bdj", "tvos-bdj-device-build"))
        if args.command in ("tvos-build", "tvos-runtime", "tvos-smoke", "tvos-bdj",
                            "tvos-bdj-device-build"):
            import tvos
            tvos.build(lab, dependencies, runtime=args.command != "tvos-build",
                       simulator=args.command in ("tvos-smoke", "tvos-bdj"),
                       bdj=args.command in ("tvos-bdj", "tvos-bdj-device-build"))
            if args.command in ("tvos-bdj", "tvos-bdj-device-build"):
                import tvos_bdj
                tvos_bdj.run(lab, dependencies, simulator=args.command == "tvos-bdj")
            if args.command == "tvos-smoke":
                import tvos_smoke
                tvos_smoke.run(lab)
        if args.command == "zero-probe":
            lab.zero_probe(dependencies)
        if args.command in ("host", "navigate"):
            build = lab.host(dependencies)
            if args.command == "navigate":
                lab.navigate(dependencies, build)
    except (OSError, ValueError, RuntimeError, tarfile.TarError) as error:
        print(f"disc-menu-lab: {error}", file=sys.stderr)
        return 1
    except KeyboardInterrupt:
        print("disc-menu-lab: cancelled; owned command stopped", file=sys.stderr)
        return 130
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
