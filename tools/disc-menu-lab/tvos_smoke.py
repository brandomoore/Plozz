"""Build and run an original Java probe in one owned, bounded tvOS simulator."""
import json
from pathlib import Path
import plistlib
import shutil
import time
import uuid


def validate_result(result: dict, *, simulator: bool = True, run_id: str | None = None,
                    mobile: bool = False) -> None:
    platform = ("iOS" if mobile else "tvOS") + (" Simulator" if simulator else "")
    if (result.get("status") != "pass" or result.get("platform") != platform
            or result.get("physical_device") is not (not simulator)):
        raise RuntimeError(f"Java runtime probe did not pass: {result}")
    if run_id is not None and result.get("run_id") != run_id:
        raise RuntimeError("Runtime evidence belongs to a different lab invocation")


def build_app(lab, *, bdj: dict | None = None, simulator: bool = True, mobile: bool = False) -> Path:
    from lab import HERE
    sdk_name = ("iphone" if mobile else "appletv") + ("simulator" if simulator else "os")
    target = ("arm64-apple-ios18.0" if mobile else "arm64-apple-tvos18.0") + ("-simulator" if simulator else "")
    app = lab.run_dir / "ZeroSmoke.app"
    app.mkdir()
    shutil.copytree(lab.run_dir / "runtime", app / "runtime")
    classes = app / "classes"
    classes.mkdir()
    java = Path(lab.environment["JAVA_HOME"])
    if not bdj:
        lab.run("compile-java-runtime-probe", [
            java / "bin/javac", "-d", classes, HERE / "RuntimeSmoke.java", HERE / "StorageSmoke.java",
        ])
    else:
        for directory in ("disc", "jars"):
            shutil.copytree(lab.run_dir / directory, app / directory)
    lab.run("smoke-sdk", ["xcrun", "--sdk", sdk_name, "--show-sdk-path"])
    sdk = (lab.run_dir / lab.commands[-1]["log"]).read_text().strip()
    extra = []
    if bdj:
        lab.run("compile-embedded-navigation", [
            "xcrun", "--sdk", sdk_name, "clang",
            "-target", target, "-isysroot", sdk,
            "-DPLOZZ_EMBEDDED_NAVIGATION", "-I", bdj["include"],
            "-c", HERE / "navigation.c", "-o", lab.run_dir / "navigation.o",
        ])
        extra = ["-DPLOZZ_BDJ_SMOKE", lab.run_dir / "navigation.o", *bdj["link"]]
    lab.run("compile-runtime-smoke-app", [
        "xcrun", "--sdk", sdk_name, "clang",
        "-target", target, "-isysroot", sdk,
        "-fobjc-arc", "-Wall", "-Wextra", "-Werror",
        "-I", java / "include", "-I", java / "include/darwin",
        HERE / "runtime_smoke.m", "-o", app / "ZeroSmoke",
        "-L", app / "runtime/lib/zero", "-ljvm",
        "-Wl,-rpath,@executable_path/runtime/lib/zero",
        "-Wl,-rpath,@executable_path/runtime/lib",
        *extra,
        "-framework", "UIKit", "-framework", "Foundation", "-framework", "CoreGraphics",
    ])
    identifier = "app.plozz.lab.ZeroSmoke"
    with (app / "Info.plist").open("wb") as output:
        plistlib.dump({
            "CFBundleIdentifier": identifier, "CFBundleExecutable": "ZeroSmoke",
            "CFBundleName": "Disc Menu Lab" if bdj else "Zero Smoke",
            "CFBundlePackageType": "APPL",
            "CFBundleVersion": "1", "CFBundleShortVersionString": "1.0",
            "PlozzLabRunID": lab.run_dir.name,
            "MinimumOSVersion": "18.0", "UIDeviceFamily": [1, 2] if mobile else [3],
            "CFBundleSupportedPlatforms": [
                ("iPhoneSimulator" if simulator else "iPhoneOS") if mobile
                else ("AppleTVSimulator" if simulator else "AppleTVOS")],
            "UILaunchScreen": {},
            "UIApplicationSceneManifest": {
                "UIApplicationSupportsMultipleScenes": False,
                "UISceneConfigurations": {
                    "UIWindowSceneSessionRoleApplication": [{
                        "UISceneConfigurationName": "Default",
                        "UISceneDelegateClassName": "SmokeScene",
                    }],
                },
            },
        }, output)
    return app


def run(lab, *, bdj: dict | None = None, mobile: bool = False) -> None:
    app = build_app(lab, bdj=bdj, mobile=mobile)
    for index, library in enumerate(sorted(app.rglob("*.dylib"))):
        lab.run(f"sign-smoke-library-{index}", ["codesign", "--force", "--sign", "-", library])
    lab.run("sign-runtime-smoke-app", ["codesign", "--force", "--sign", "-", app])
    execute(lab, app, "app.plozz.lab.ZeroSmoke", mobile=mobile, artifacts=(
        ("menu-first.ppm", "menu-second.ppm", "episode-1.m2ts", "episode-2.m2ts")
        if bdj else ()))


def execute(lab, app: Path, identifier: str, *, artifacts: tuple[str, ...] = (),
            mobile: bool = False) -> None:
    lab.run("list-smoke-runtimes", ["xcrun", "simctl", "list", "runtimes", "-j"], timeout=30)
    runtimes = json.loads((lab.run_dir / lab.commands[-1]["log"]).read_text())["runtimes"]
    available = [
        runtime for runtime in runtimes
        if runtime.get("isAvailable") and runtime["identifier"].startswith(
            "com.apple.CoreSimulator.SimRuntime." + ("iOS-" if mobile else "tvOS-"))
        and int(runtime["version"].split(".")[0]) >= 18
        and (not mobile or any(device.get("productFamily") == "iPad"
                               for device in runtime.get("supportedDeviceTypes", [])))
    ]
    if not available:
        raise RuntimeError(f"No compatible {'iPad' if mobile else 'tvOS'} simulator runtime is installed")
    runtime = max(available, key=lambda value: tuple(map(int, value["version"].split("."))))
    device_type = "com.apple.CoreSimulator.SimDeviceType.Apple-TV-4K-3rd-generation-1080p"
    if mobile:
        devices = [device["identifier"] for device in runtime.get("supportedDeviceTypes", [])
                   if device.get("productFamily") == "iPad"]
        if not devices:
            raise RuntimeError("Selected iOS runtime does not declare a compatible iPad")
        device_type = devices[0]
    simulator = None
    container = None
    cleanup_errors = []
    try:
        lab.run("create-owned-smoke-simulator", [
            "xcrun", "simctl", "create", f"Plozz Zero {lab.run_dir.name[:8]}",
            device_type,
            runtime["identifier"],
        ], timeout=60)
        simulator = str(uuid.UUID((lab.run_dir / lab.commands[-1]["log"]).read_text().strip()))
        (lab.run_dir / "simulator.json").write_text(json.dumps({
            "id": simulator, "runtime": runtime["identifier"], "owner": lab.run_dir.name,
        }, indent=2) + "\n")
        lab.run("boot-owned-smoke-simulator", ["xcrun", "simctl", "boot", simulator], timeout=60)
        lab.run("wait-owned-smoke-simulator", [
            "xcrun", "simctl", "bootstatus", simulator, "-b",
        ], timeout=180)
        lab.run("install-owned-smoke-app", ["xcrun", "simctl", "install", simulator, app], timeout=60)
        lab.run("locate-owned-smoke-container", [
            "xcrun", "simctl", "get_app_container", simulator, identifier, "data",
        ], timeout=30)
        container = Path((lab.run_dir / lab.commands[-1]["log"]).read_text().strip())
        if not container.is_absolute() or not container.is_dir():
            raise RuntimeError("Simulator returned an invalid app data container")
        lab.run("launch-owned-smoke-app", [
            "xcrun", "simctl", "launch",
            f"--stdout={lab.run_dir / 'app-stdout.log'}",
            f"--stderr={lab.run_dir / 'app-stderr.log'}", simulator, identifier,
        ], timeout=90)
        result_path = container / "Library/Caches/runtime-result.json"
        deadline = time.monotonic() + 120
        while not result_path.exists():
            if time.monotonic() >= deadline:
                for crash in (container / "tmp").glob("hs_err_pid*.log"):
                    shutil.copy2(crash, lab.run_dir / crash.name)
                raise RuntimeError("Java execution did not produce a result within 120s")
            time.sleep(1)
        result = json.loads(result_path.read_text())
        (lab.run_dir / "runtime-result.json").write_text(json.dumps(result, indent=2) + "\n")
        validate_result(result, run_id=lab.run_dir.name, mobile=mobile)
        for name in artifacts:
            shutil.copy2(container / "Library/Caches" / name, lab.run_dir / name)
        if artifacts:
            lab.run("capture-owned-bdj-screen", [
                "xcrun", "simctl", "io", simulator, "screenshot", lab.run_dir / "simulator-menu.png",
            ], timeout=30)
    finally:
        if container is not None:
            for name in ("stdout", "stderr"):
                log = container / f"Library/Caches/runtime-{name}.log"
                if log.exists():
                    try:
                        shutil.copy2(log, lab.run_dir / f"app-{name}.log")
                    except OSError as error:
                        cleanup_errors.append(f"Could not retain runtime {name}: {error}")
        if simulator:
            for name, operation in (("shutdown", "shutdown"), ("delete", "delete")):
                try:
                    lab.run(f"{name}-owned-smoke-simulator",
                            ["xcrun", "simctl", operation, simulator], timeout=60)
                except (OSError, RuntimeError) as error:
                    cleanup_errors.append(str(error))
            (lab.run_dir / "simulator-cleanup.json").write_text(json.dumps({
                "id": simulator, "errors": cleanup_errors,
                "status": "failed" if cleanup_errors else "complete",
            }, indent=2) + "\n")
            if cleanup_errors:
                raise RuntimeError("Owned simulator cleanup failed: " + "; ".join(cleanup_errors))
