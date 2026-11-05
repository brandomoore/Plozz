"""Package the isolated HDMV/AetherEngine lab; never sign or install automatically."""
import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import shutil

from lab import HERE, ROOT, WORK, Lab
import player_build
from tvos import validate_platform


def build(lab, configuration, *, region, simulator=False):
    if region not in (1, 2, 4):
        raise ValueError("Select exactly one player region")
    products = player_build.build(lab, simulator=simulator)
    variant = "tvossim" if simulator else "tvos"
    sdk_name = "appletvsimulator" if simulator else "appletvos"
    target = "arm64-apple-tvos18.0" + ("-simulator" if simulator else "")
    source = WORK / ("libbluray-tvos-source" if simulator else "libbluray-device-source")
    native = WORK / f"libbluray-{variant}-build"
    if not (native / "build.ninja").exists():
        raise ValueError("Build the existing tvOS libbluray port before the live lab")
    lab.run("compile-live-libbluray", ["meson", "compile", "-C", native, "-j", "4"], timeout=600)
    app = lab.run_dir / "DiscMenuLab.app"
    frameworks = app / "Frameworks"
    frameworks.mkdir(parents=True)
    pending = ["DiscMenuPlayer"]
    embedded = set()
    while pending:
        name = pending.pop()
        if name in embedded:
            continue
        candidates = [products / f"{name}.framework", products / f"PackageFrameworks/{name}.framework"]
        matches = [path for path in candidates if path.is_dir()]
        if not matches:
            raise ValueError(f"Expected one freshly built framework: {name}")
        if len(matches) > 1:
            hashes = []
            for match in matches:
                with (match / name).open("rb") as binary:
                    hashes.append(hashlib.file_digest(binary, "sha256").hexdigest())
            if len(set(hashes)) != 1:
                raise ValueError(f"Ambiguous built framework: {name}")
        framework = matches[0]
        lab.run(f"inspect-live-{name}", ["otool", "-L", framework / name])
        for line in (lab.run_dir / lab.commands[-1]["log"]).read_text().splitlines()[1:]:
            path = line.strip().split(" ", 1)[0]
            if path.startswith("@rpath/") and ".framework/" in path:
                pending.append(path.split("/")[1].removesuffix(".framework"))
        lab.run(f"verify-live-{name}-platform", ["otool", "-l", framework / name])
        headers = (lab.run_dir / lab.commands[-1]["log"]).read_text()
        lab.run(f"verify-live-{name}-architecture", ["lipo", "-archs", framework / name])
        validate_platform(headers, (lab.run_dir / lab.commands[-1]["log"]).read_text(),
                          simulator=simulator)
        shutil.copytree(framework, frameworks / framework.name)
        embedded.add(name)
    shutil.copytree(products / "AetherEngine_AetherEngine.bundle", app / "AetherEngine_AetherEngine.bundle")
    runtime = app / "runtime/lib"
    runtime.mkdir(parents=True)
    jdk_builds = list(WORK.glob(f"jdk21u-*-{variant}-build"))
    if len(jdk_builds) != 1:
        raise ValueError("Expected the existing pinned native FreeType build")
    shutil.copy2(jdk_builds[0] / "support/modules_libs/java.desktop/libfreetype.dylib", runtime)
    shutil.copy2(configuration, app / "disc.json")
    config = json.loads((app / "disc.json").read_text())
    config["regionCode"] = region
    (app / "disc.json").chmod(0o600)
    (app / "disc.json").write_text(json.dumps(config) + "\n")
    lab.run("live-sdk", ["xcrun", "--sdk", sdk_name, "--show-sdk-path"])
    sdk = (lab.run_dir / lab.commands[-1]["log"]).read_text().strip()
    generated = products.parent.parent / "Intermediates.noindex" / (
        "GeneratedModuleMaps-appletvsimulator" if simulator else "GeneratedModuleMaps-appletvos"
    )
    lab.run("compile-live-disc-app", [
        "xcrun", "--sdk", sdk_name, "clang", "-target", target, "-isysroot", sdk,
        "-fobjc-arc", "-Wall", "-Wextra", "-Werror",
        "-I", generated, "-I", source / "src", "-I", HERE,
        HERE / "hdmv_session.m", HERE / "live_app.m",
        native / "src/libbluray.a", native / "contrib/libudfread/src/libudfread.a",
        "-F", frameworks, "-framework", "DiscMenuPlayer",
        "-L", runtime, "-lfreetype", "-framework", "UIKit", "-framework", "Foundation",
        "-framework", "CoreGraphics", "-framework", "CoreFoundation", "-framework", "AVFAudio",
        "-Wl,-rpath,@executable_path/Frameworks", "-Wl,-rpath,@executable_path/runtime/lib",
        "-o", app / "DiscMenuLab",
    ])
    with (app / "Info.plist").open("wb") as output:
        plistlib.dump({
            "CFBundleIdentifier": "app.plozz.lab.ZeroSmoke", "CFBundleExecutable": "DiscMenuLab",
            "CFBundleName": "Disc Menu Lab", "CFBundleDisplayName": "Disc Menu Lab",
            "CFBundlePackageType": "APPL", "CFBundleVersion": "2",
            "CFBundleShortVersionString": "0.2", "PlozzLabRunID": lab.run_dir.name,
            "MinimumOSVersion": "18.0", "UIDeviceFamily": [3],
            "CFBundleSupportedPlatforms": ["AppleTVSimulator" if simulator else "AppleTVOS"],
            "UILaunchScreen": {},
            "NSLocalNetworkUsageDescription": "Read the selected disc from its temporary local-network relay.",
            "NSAppTransportSecurity": {"NSAllowsArbitraryLoads": True},
            "UIApplicationSceneManifest": {
                "UIApplicationSupportsMultipleScenes": False,
                "UISceneConfigurations": {"UIWindowSceneSessionRoleApplication": [{
                    "UISceneConfigurationName": "Default", "UISceneDelegateClassName": "LiveScene",
                }]},
            },
        }, output)
    licenses = app / "Licenses"
    licenses.mkdir()
    shutil.copy2(source / "COPYING", licenses / "libbluray.txt")
    shutil.copy2(source / "contrib/libudfread/COPYING", licenses / "libudfread.txt")
    checkouts = ROOT / ".build/package-workspaces/disc-menu-player/checkouts"
    for package in ("AetherEngine", "FFmpegBuild", "LibDovi"):
        shutil.copy2(checkouts / package / "LICENSE", licenses / f"{package}.txt")
    shutil.copytree(checkouts / "FFmpegBuild/LICENSES", licenses / "multimedia")
    jdk_source = WORK / jdk_builds[0].name.replace(f"-{variant}-build", "-tvos-source")
    shutil.copy2(jdk_source / "src/java.desktop/share/legal/freetype.md", licenses)
    for name in ("LICENSE", "ADDITIONAL_LICENSE_INFO", "ASSEMBLY_EXCEPTION"):
        shutil.copy2(jdk_source / name, licenses / f"OpenJDK-{name}.txt")
    (lab.run_dir / "live-build.json").write_text(json.dumps({
        "status": "built-not-signed-or-installed", "app": str(app),
        "simulator": simulator, "frameworks": sorted(embedded),
    }, indent=2) + "\n")
    return app


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--configuration", type=Path, required=True)
    parser.add_argument("--simulator", action="store_true")
    parser.add_argument("--region", choices=("A", "B", "C"), required=True)
    arguments = parser.parse_args()
    build(Lab(), arguments.configuration.resolve(strict=True),
          region={"A": 1, "B": 2, "C": 4}[arguments.region], simulator=arguments.simulator)
