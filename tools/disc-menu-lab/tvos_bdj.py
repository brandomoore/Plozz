"""Original-disc BD-J integration on the isolated tvOS Zero runtime."""
import json
from pathlib import Path
import shutil
import sys

from tvos import replace_once, validate_platform


def validate_menu(data: bytes, selected: int, *, rendered: bool = False) -> None:
    if selected not in (1, 2):
        raise ValueError("The authored fixture has exactly two choices")
    header = b"P6\n1280 720\n255\n"
    if not data.startswith(header) or len(data) != len(header) + 1280 * 720 * 3:
        raise ValueError("Missing or malformed 1280x720 RGB menu snapshot")
    pixels = memoryview(data)[len(header):]
    for episode, x in ((1, 100), (2, 680)):
        expected = b"\xff\xff\x00" if episode == selected else b"\x80\x80\x80"
        for y in range(270, 290):
            for column in range(x, x + 20):
                offset = (y * 1280 + column) * 3
                if pixels[offset:offset + 3] != expected:
                    raise ValueError(f"Menu selection {selected} has incorrect card {episode}")
    # Display scaling antialiases text; raw Java buffers must remain exact.
    white_minimum, black_maximum = (223, 32) if rendered else (255, 0)
    title_pixels = sum(
        min(pixels[(y * 1280 + x) * 3:(y * 1280 + x) * 3 + 3]) >= white_minimum
        for y in range(70, 115) for x in range(80, 650))
    if title_pixels < 500:
        raise ValueError("Menu title text did not render")
    for left in (120, 700):
        text_pixels = sum(
            max(pixels[(y * 1280 + x) * 3:(y * 1280 + x) * 3 + 3]) <= black_maximum
            for y in range(315, 345) for x in range(left, left + 180))
        if text_pixels < 100:
            raise ValueError("Episode label text did not render")


def prepare_bluray(pristine: Path, source: Path, jdk_source: Path, native: Path) -> None:
    if not source.exists():
        shutil.copytree(pristine, source, symlinks=True)
    patches = {
        "meson.build": [
            ("modules: ['CoreFoundation', 'DiskArbitration']", "modules: ['CoreFoundation']"),
            (
                "freetype_dependency = dependency('freetype2', required: get_option('freetype'))",
                "freetype_dependency = declare_dependency(\n"
                f"    include_directories: include_directories('{jdk_source}/src/java.desktop/share/native/libfreetype/include'),\n"
                f"    link_args: ['{native}/libfreetype.dylib'])",
            ),
        ],
        "src/meson.build": [
            ("'file/mount_darwin.c'", "'file/mount.c'"),
        ],
        "src/libbluray/bdj/java/org/videolan/Libbluray.java": [
            ('System.setProperty("bluray.network.connected", "YES");',
             'System.setProperty("bluray.network.connected", "NO");'),
        ],
    }
    for relative, replacements in patches.items():
        text = (pristine / relative).read_text()
        # Host experiment already applies this one security restriction.
        if relative.endswith("Libbluray.java") and replacements[0][1] in text:
            replacements = []
        for before, after in replacements:
            text = replace_once(text, before, after)
        write_changed(source / relative, text)
    relative = "src/libbluray/bdj/bdj.c"
    text = (pristine / relative).read_text()
    guard = "#if defined(__APPLE__) && !defined(HAVE_BDJ_J2ME)"
    if text.count(guard) != 7:
        raise ValueError("Unexpected desktop Java discovery guards")
    text = text.replace(guard, guard + " && !defined(PLOZZ_TVOS)")
    text = replace_once(text, 'static const char * const jvm_dir[]  = {"jre/lib/server",\n'
                        '                                            "lib/server"};',
                        'static const char * const jvm_dir[] = {"lib/zero"};')
    text = replace_once(text, "    /* JAVA_HOME set, use it */\n    java_home = getenv(\"JAVA_HOME\");\n    if (java_home) {\n        BD_DEBUG(DBG_BDJ, \"Using JAVA_HOME",
                        '    BD_DEBUG(DBG_BDJ | DBG_CRIT, "tvOS requires an application-provided runtime path\\n");\n'
                        "    return NULL;\n\n"
                        "    /* JAVA_HOME set, use it */\n    java_home = getenv(\"JAVA_HOME\");\n    if (java_home) {\n        BD_DEBUG(DBG_BDJ, \"Using JAVA_HOME")
    write_changed(source / relative, text)
    relative = "src/libbluray/bdj/java/java/awt/BDFontMetrics.java"
    text = (pristine / relative).read_text()
    for original, replacement in {
        "LucidaBrightRegular": "DejaVuSerif", "LucidaBrightDemiBold": "DejaVuSerif-Bold",
        "LucidaBrightItalic": "DejaVuSerif-Italic", "LucidaBrightDemiItalic": "DejaVuSerif-BoldItalic",
        "LucidaSansRegular": "DejaVuSans", "LucidaSansDemiBold": "DejaVuSans-Bold",
        "LucidaSansOblique": "DejaVuSans-Oblique", "LucidaSansDemiOblique": "DejaVuSans-BoldOblique",
        "LucidaTypewriterRegular": "DejaVuSansMono", "LucidaTypewriterBold": "DejaVuSansMono-Bold",
        "LucidaTypewriterOblique": "DejaVuSansMono-Oblique",
        "LucidaTypewriterBoldOblique": "DejaVuSansMono-BoldOblique",
    }.items():
        if original + ".ttf" not in text:
            raise ValueError(f"Missing font mapping: {original}")
        text = text.replace(original + ".ttf", replacement + ".ttf")
    write_changed(source / relative, text)


def write_changed(path: Path, text: str) -> None:
    if not path.exists() or path.read_text() != text:
        path.write_text(text)


def run(lab, dependencies: dict[str, Path], *, simulator: bool = True) -> None:
    from lab import HERE, ROOT, WORK
    import fixture
    import tvos_smoke
    variant = "tvossim" if simulator else "tvos"
    sdk_name = "appletvsimulator" if simulator else "appletvos"
    target = "arm64-apple-tvos18.0" + ("-simulator" if simulator else "")
    source = WORK / ("libbluray-tvos-source" if simulator else "libbluray-device-source")
    jdk_source = WORK / f"{dependencies['zero-source'].name}-tvos-source"
    jdk_build = WORK / f"{dependencies['zero-source'].name}-{variant}-build"
    native = jdk_build / "support/modules_libs/java.desktop"
    prepare_bluray(dependencies["libbluray"], source, jdk_source, native)
    lab.run("bdj-sdk", ["xcrun", "--sdk", sdk_name, "--show-sdk-path"])
    sdk = (lab.run_dir / lab.commands[-1]["log"]).read_text().strip()
    cross = WORK / f"libbluray-{variant}.cross"
    write_changed(cross, (
        "[binaries]\nc = 'clang'\nar = 'ar'\nstrip = 'strip'\n"
        "[host_machine]\nsystem = 'darwin'\ncpu_family = 'aarch64'\ncpu = 'arm64'\nendian = 'little'\n"
        "[properties]\nneeds_exe_wrapper = true\npkg_config_libdir = []\n"
        "[built-in options]\n"
        f"c_args = ['-target', '{target}', '-isysroot', '{sdk}', '-DPLOZZ_TVOS=1']\n"
        f"c_link_args = ['-target', '{target}', '-isysroot', '{sdk}']\n"))
    build = WORK / f"libbluray-{variant}-build"
    if not (build / "build.ninja").exists():
        lab.run(f"configure-{variant}-libbluray", [
            "meson", "setup", build, source, "--cross-file", cross,
            "--force-fallback-for=libudfread", "-Ddefault_library=static",
            "-Dbdj_jar=disabled", "-Denable_tools=false", "-Denable_devtools=false",
            "-Dfontconfig=disabled", "-Dlibxml2=disabled",
            f"-Djdk_home={lab.environment['JAVA_HOME']}",
        ])
    lab.run(f"compile-{variant}-libbluray", ["meson", "compile", "-C", build, "-j", "4"],
            timeout=600)
    jars = lab.run_dir / "jars"
    jars.mkdir()
    java = Path(lab.environment["JAVA_HOME"]) / "bin"
    lab.run(f"compile-{variant}-bdj-jars", [
        "ant", "-f", source / "src/libbluray/bdj/build.xml",
        f"-Dbuild={WORK / (variant + '-bdj-classes')}", f"-Ddist={jars}",
        "-Dbootclasspath=", "-Dsrc_awt=:java-j2se:java-build-support",
        f"-Djavac_path={java / 'javac'}", "-Djavac_arg=-Xlint:-removal",
        "-Dversion=j2se-1.5.0", "-Djava_version_asm=1.8", "-Djava_version_bdj=1.8",
    ], timeout=300)
    font_root = dependencies["menu-fonts"]
    shutil.copytree(font_root / "ttf", lab.run_dir / "runtime/lib/fonts")
    license_dir = lab.run_dir / "runtime/legal/dejavu"
    license_dir.mkdir()
    shutil.copy2(font_root / "LICENSE", license_dir / "LICENSE")
    for name, origin in (("libbluray", dependencies["libbluray"]),
                         ("libudfread", dependencies["libbluray"] / "contrib/libudfread")):
        destination = lab.run_dir / "runtime/legal" / name
        destination.mkdir()
        shutil.copy2(origin / "COPYING", destination / "COPYING")
    for index, library in enumerate(sorted((lab.run_dir / "runtime/lib").rglob("*.dylib"))):
        lab.run(f"verify-bdj-library-{index}", ["otool", "-l", library])
        headers = (lab.run_dir / lab.commands[-1]["log"]).read_text()
        lab.run(f"verify-bdj-architecture-{index}", ["lipo", "-archs", library])
        validate_platform(headers, (lab.run_dir / lab.commands[-1]["log"]).read_text(),
                          simulator=simulator)
    clips = lab.run_dir / "clips"
    lab.run("generate-bdj-clips", [
        sys.executable, ROOT / "tools/generate-bdmv-test-fixture.py", "--output", clips,
    ], timeout=400)
    fixture.create(lab.run_dir / "disc", clips / "BDMV/STREAM")
    classes = lab.run_dir / "xlet"
    classes.mkdir()
    lab.run("compile-target-xlet", [
        java / "javac", "--release", "8", "-classpath",
        jars / "libbluray-j2se-1.5.0.jar", "-d", classes, HERE / "MenuXlet.java",
    ])
    lab.run("package-target-xlet", [
        java / "jar", "--create", "--file", lab.run_dir / "disc/BDMV/JAR/00000.jar",
        "-C", classes, ".",
    ])
    configuration = {
        "include": source / "src",
        "link": [build / "src/libbluray.a",
                 build / "contrib/libudfread/src/libudfread.a",
                 "-L", lab.run_dir / "runtime/lib", "-lfreetype",
                 "-framework", "CoreFoundation"],
    }
    if not simulator:
        app = tvos_smoke.build_app(lab, bdj=configuration, simulator=False)
        (lab.run_dir / "bdj-result.json").write_text(json.dumps({
            "status": "device-app-built-not-signed-or-executed",
            "platform": "tvOS", "physical_device": True,
            "app": str(app), "runtime": "OpenJDK Zero 21",
        }, indent=2) + "\n")
        return
    tvos_smoke.run(lab, bdj=configuration)
    verify_navigation(lab)


def verify_navigation(lab, *, simulator: bool = True) -> None:
    for selected, menu in enumerate(("first", "second"), start=1):
        validate_menu((lab.run_dir / f"menu-{menu}.ppm").read_bytes(), selected)
        lab.run(f"export-tvos-menu-{menu}", [
            "ffmpeg", "-hide_banner", "-loglevel", "error", "-i",
            lab.run_dir / f"menu-{menu}.ppm", "-frames:v", "1",
            lab.run_dir / f"menu-{menu}.png",
        ])
    for episode, component in ((1, 0), (2, 2)):
        lab.run(f"decode-tvos-episode-{episode}", [
            "ffmpeg", "-hide_banner", "-loglevel", "error", "-xerror",
            "-i", lab.run_dir / f"episode-{episode}.m2ts", "-frames:v", "1",
            "-vf", "scale=1:1", "-pix_fmt", "rgb24", "-f", "rawvideo",
            lab.run_dir / f"episode-{episode}.rgb",
        ])
        pixel = (lab.run_dir / f"episode-{episode}.rgb").read_bytes()
        if len(pixel) != 3 or pixel[component] < 200 or any(
                channel > 50 for index, channel in enumerate(pixel) if index != component):
            raise RuntimeError(f"Wrong decoded episode {episode}: {pixel!r}")
    screen = "simulator-menu.png" if simulator else "hardware-screen.png"
    lab.run("normalize-presented-menu", [
        "ffmpeg", "-hide_banner", "-loglevel", "error", "-i", lab.run_dir / screen,
        "-frames:v", "1", "-vf", "scale=1280:720", "-pix_fmt", "rgb24",
        lab.run_dir / "presented-menu.ppm",
    ])
    validate_menu((lab.run_dir / "presented-menu.ppm").read_bytes(), 2, rendered=True)
    (lab.run_dir / "bdj-result.json").write_text(json.dumps({
        "status": "pass", "runtime": "OpenJDK Zero 21",
        "platform": "tvOS Simulator" if simulator else "tvOS",
        "physical_device": not simulator, "playlists": [1, 2], "continuous_playback": False,
        "completed_screen": "captured-menu-not-interactive",
    }, indent=2) + "\n")
