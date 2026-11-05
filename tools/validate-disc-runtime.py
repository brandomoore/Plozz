#!/usr/bin/env python3
"""Check distribution artifacts; this is not an App Review or licensing verdict."""
import argparse
from pathlib import Path
import plistlib
import re
import subprocess


PROCESS_IMPORTS = {"_fork", "_vfork", "_execve", "_posix_spawn", "_posix_spawnp", "_system", "_ptrace"}


def command(*args):
    return subprocess.check_output(args, text=True, stderr=subprocess.STDOUT, timeout=60)


def process_imports(output):
    return sorted({line.split()[-1] for line in output.splitlines() if line.split()} & PROCESS_IMPORTS)


def os_version(value):
    if not re.fullmatch(r"\d+(?:\.\d+){0,2}", value):
        raise ValueError(f"Invalid minimum OS version: {value}")
    parts = tuple(map(int, value.split(".")))
    return parts + (0,) * (3 - len(parts))


def dependency_path(dependency, binary, app, executable_root=None):
    if dependency.startswith(("/System/Library/", "/usr/lib/")):
        return None
    executable_root = executable_root or app
    roots = [("@rpath/", executable_root / "Frameworks")]
    if executable_root != app:
        roots.append(("@rpath/", app / "Frameworks"))
    roots.extend((("@loader_path/", binary.parent), ("@executable_path/", executable_root)))
    matched = False
    for prefix, root in roots:
        if dependency.startswith(prefix):
            matched = True
            candidate = (root / dependency[len(prefix):]).resolve()
            if not candidate.is_relative_to(app.resolve()):
                raise ValueError(f"Native dependency escapes app: {dependency}")
            # Swift system libraries may be supplied by the device OS.
            if prefix == "@rpath/" and re.fullmatch(r"libswift[A-Za-z0-9_]+\.dylib", dependency[len(prefix):]):
                return None
            if candidate.is_file():
                return candidate
    if matched:
        raise ValueError(f"Missing native dependency: {dependency}")
    raise ValueError(f"Unbundled native dependency: {dependency}")


def bundle_executable(bundle, metadata):
    name = metadata["CFBundleExecutable"]
    if not isinstance(name, str) or not name or Path(name).name != name or name in (".", ".."):
        raise ValueError(f"Invalid bundle executable: {bundle.name}")
    binary = bundle / name
    if not binary.is_file() or not binary.resolve().is_relative_to(bundle.resolve()):
        raise ValueError(f"Invalid bundle executable: {bundle.name}")
    return binary


def bundled_binaries(app, info):
    binaries = []
    for container in [app, *sorted((app / "PlugIns").glob("*.appex"))]:
        metadata = info if container == app else plistlib.loads((container / "Info.plist").read_bytes())
        if metadata["CFBundleSupportedPlatforms"] != info["CFBundleSupportedPlatforms"]:
            raise ValueError(f"Wrong extension platform: {container.name}")
        if container != app and any(metadata[key] != info[key] for key in
                                    ("CFBundleVersion", "CFBundleShortVersionString")):
            raise ValueError(f"Extension version differs from app: {container.name}")
        binaries.append((bundle_executable(container, metadata), container))
        for framework in sorted((container / "Frameworks").glob("*.framework")):
            framework_info = plistlib.loads((framework / "Info.plist").read_bytes())
            binary = bundle_executable(framework, framework_info)
            if framework.name.startswith("PlozzBDJ"):
                if framework_info.get("CFBundlePackageType") != "FMWK" or binary.name != framework.stem:
                    raise ValueError(f"Invalid disc framework metadata: {framework.name}")
                if framework_info.get("CFBundleSupportedPlatforms") != info["CFBundleSupportedPlatforms"]:
                    raise ValueError(f"Wrong disc framework platform: {framework.name}")
                if os_version(framework_info["MinimumOSVersion"]) > os_version(metadata["MinimumOSVersion"]):
                    raise ValueError(f"Disc framework requires a newer OS: {framework.name}")
            binaries.append((binary, container))
        for library in sorted((container / "Frameworks").glob("*.dylib")):
            if not re.fullmatch(r"libswift[A-Za-z0-9_]+\.dylib", library.name):
                raise ValueError(f"Unwrapped dynamic library: {library.name}")
            binaries.append((library, container))
    expected = {binary.resolve() for binary, _ in binaries}
    macho_magic = {b"\xfe\xed\xfa\xce", b"\xce\xfa\xed\xfe", b"\xfe\xed\xfa\xcf",
                   b"\xcf\xfa\xed\xfe", b"\xca\xfe\xba\xbe", b"\xbe\xba\xfe\xca",
                   b"\xca\xfe\xba\xbf", b"\xbf\xba\xfe\xca"}
    for resource in app.rglob("*"):
        if not resource.is_file() or resource.resolve() in expected:
            continue
        # Java class files share FAT_MAGIC. They are interpreted resources, not Mach-O.
        if resource.suffix == ".class" and resource.is_relative_to(app / "DiscRuntime/modules"):
            continue
        with resource.open("rb") as stream:
            if stream.read(4) in macho_magic:
                raise ValueError(f"Unexpected native executable: {resource.relative_to(app)}")
    return binaries


def validate(app):
    info = plistlib.loads((app / "Info.plist").read_bytes())
    supported = info["CFBundleSupportedPlatforms"]
    expected = {"AppleTVOS": {"3", "TVOS"}, "iPhoneOS": {"2", "IOS"}}
    if len(supported) != 1 or supported[0] not in expected:
        raise ValueError("A device distribution app is required, not a simulator app")
    runtime = app / "DiscRuntime"
    if not (runtime / "jars/libbluray-j2se-1.5.0.jar").is_file():
        raise ValueError("Missing bundled disc Java classes")
    for notice in ("java.base", "java.desktop", "libbluray", "asm", "dejavu", "libffi"):
        if not (runtime / "legal" / notice).is_dir():
            raise ValueError(f"Missing runtime notice directory: {notice}")
    for resource in runtime.rglob("*"):
        if resource.is_file() and (resource.suffix == ".dylib" or resource.stat().st_mode & 0o111):
            raise ValueError(f"Executable code or executable resource in DiscRuntime: {resource.name}")
    if not (app / "Frameworks/PlozzBDJjvm.framework/PlozzBDJjvm").is_file():
        raise ValueError("Missing embedded JVM framework")
    binaries = bundled_binaries(app, info)
    failures = []
    for binary, executable_root in binaries:
        architectures = command("lipo", "-archs", str(binary)).split()
        if not architectures or not set(architectures) <= {"arm64", "arm64e"}:
            failures.append(f"{binary.name}: invalid device architecture")
        platforms = re.findall(r"^\s*platform\s+(\S+)", command("otool", "-l", str(binary)), re.MULTILINE)
        if not platforms or not set(platforms) <= expected[supported[0]]:
            failures.append(f"{binary.name}: invalid device platform")
        imports = process_imports(command("nm", "-u", str(binary)))
        if imports:
            failures.append(f"{binary.name}: process imports {', '.join(imports)}")
        for line in command("otool", "-L", str(binary)).splitlines()[1:]:
            dependency = line.strip().split(" (", 1)[0]
            dependency_path(dependency, binary, app, executable_root)
    if failures:
        raise ValueError("\n".join(failures))
    command("codesign", "--verify", "--deep", "--strict", str(app))
    return len(binaries)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, required=True)
    args = parser.parse_args()
    try:
        count = validate(args.app.resolve())
    except (ValueError, KeyError, OSError, subprocess.SubprocessError) as error:
        raise SystemExit(f"Disc distribution artifact validation failed: {error}") from error
    print(f"Disc artifact checks passed for {count} binaries. Apple review and licensing remain separate gates.")


if __name__ == "__main__":
    main()
