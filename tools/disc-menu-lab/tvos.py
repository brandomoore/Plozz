"""Reproducible, experimental Apple TV adaptations of the pinned Zero sources."""
from pathlib import Path
import hashlib
import json
import platform
import re
import shutil


def replace_once(text: str, original: str, replacement: str) -> str:
    if text.count(original) != 1:
        raise ValueError(f"Zero source patch must match exactly once: {original[:100]!r}")
    return text.replace(original, replacement)


def validate_platform(headers: str, architecture: str, *, simulator: bool = False, mobile: bool = False) -> None:
    platforms = re.findall(r"^\s*platform\s+(\S+)", headers, re.MULTILINE)
    expected = ("7" if simulator else "2") if mobile else ("8" if simulator else "3")
    if platforms != [expected] or architecture.strip() != "arm64":
        raise ValueError("Expected one arm64 binary for the selected Apple platform")


def validate_jvm(headers: str, imports: str, exports: str, architecture: str,
                 *, simulator: bool = False, mobile: bool = False) -> None:
    validate_platform(headers, architecture, simulator=simulator, mobile=mobile)
    if re.search(r"_(pthread_jit_write_protect_np|posix_spawn|fork|task_set_exception_ports)\b", imports):
        raise ValueError("The tvOS JVM still imports unsupported process/JIT APIs")
    if not re.search(r"\bT _JNI_CreateJavaVM\b", exports):
        raise ValueError("The target JVM is missing its invocation entry point")


def prepare_source(pristine: Path, destination: Path) -> None:
    if not destination.exists():
        shutil.copytree(pristine, destination, symlinks=True)
    patches = {
        "make/autoconf/toolchain.m4": [
            (
                "    UTIL_LOOKUP_TOOLCHAIN_PROGS(METAL, metal)",
                '    if test "x$ENABLE_HEADLESS_ONLY" != xtrue; then\n'
                "    UTIL_LOOKUP_TOOLCHAIN_PROGS(METAL, metal)",
            ),
            (
                '        AC_MSG_RESULT([yes, will be using \'$METALLIB\'])\n'
                "      fi\n    fi\n  fi",
                '        AC_MSG_RESULT([yes, will be using \'$METALLIB\'])\n'
                "      fi\n    fi\n    fi\n  fi",
            ),
        ],
        "make/autoconf/flags-cflags.m4": [
            (
                '    OS_CFLAGS="-DMAC_OS_X_VERSION_MIN_REQUIRED=$MACOSX_VERSION_MIN_NODOTS \\\n'
                '        -mmacosx-version-min=$MACOSX_VERSION_MIN"',
                '    OS_CFLAGS=""',
            ),
        ],
        "make/autoconf/flags-ldflags.m4": [
            ('    OS_LDFLAGS="-mmacosx-version-min=$MACOSX_VERSION_MIN"',
             '    OS_LDFLAGS=""'),
        ],
        "make/autoconf/libraries.m4": [
            (
                "  # A custom hook may have set this already",
                "  # This experimental target builds HotSpot only, not desktop printing.\n"
                "  NEEDS_LIB_CUPS=false\n\n"
                "  # A custom hook may have set this already",
            ),
        ],
        "make/autoconf/flags-other.m4": [
            (
                '    JVM_BASIC_ASFLAGS="$JVM_BASIC_ASFLAGS \\\n'
                '        -DMAC_OS_X_VERSION_MIN_REQUIRED=$MACOSX_VERSION_MIN_NODOTS \\\n'
                '        -mmacosx-version-min=$MACOSX_VERSION_MIN"',
                '    JVM_BASIC_ASFLAGS="$JVM_BASIC_ASFLAGS"',
            ),
        ],
        "src/hotspot/os/bsd/os_perf_bsd.cpp": [
            (
                "  #import <libproc.h>",
                "  #ifndef PLOZZ_TVOS\n  #import <libproc.h>\n  #endif",
            ),
            (
                '#ifdef __APPLE__\n  pid_t* pids = nullptr;',
                '#if defined(__APPLE__) && !defined(PLOZZ_TVOS)\n  pid_t* pids = nullptr;',
            ),
            (
                "  #include <net/route.h>",
                "  #ifndef PLOZZ_TVOS\n  #include <net/route.h>\n  #endif",
            ),
            (
                "int NetworkPerformanceInterface::NetworkPerformance::network_utilization(NetworkInterface** network_interfaces) const {\n",
                "int NetworkPerformanceInterface::NetworkPerformance::network_utilization(NetworkInterface** network_interfaces) const {\n"
                "#ifdef PLOZZ_TVOS\n"
                "  return FUNCTIONALITY_NOT_IMPLEMENTED;\n"
                "#else\n",
            ),
            (
                "  *network_interfaces = ret;\n\n  return OS_OK;\n}",
                "  *network_interfaces = ret;\n\n  return OS_OK;\n#endif\n}",
            ),
        ],
        "src/hotspot/os_cpu/bsd_zero/os_bsd_zero.cpp": [
            (
                "  pthread_jit_write_protect_np(mode == WXExec);",
                "#ifndef PLOZZ_TVOS\n"
                "  pthread_jit_write_protect_np(mode == WXExec);\n"
                "#else\n"
                "  // Zero's tvOS code heap holds metadata, never executable code.\n"
                "  (void)mode;\n"
                "#endif",
            ),
        ],
        "src/hotspot/share/memory/virtualspace.cpp": [
            (
                "  initialize(r_size, rs_align, rs_page_size, /*requested address*/ nullptr, /*executable*/ true);",
                "#if defined(PLOZZ_TVOS) && defined(ZERO)\n"
                "  const bool executable = false;\n"
                "#else\n"
                "  const bool executable = true;\n"
                "#endif\n"
                "  initialize(r_size, rs_align, rs_page_size, nullptr, executable);",
            ),
        ],
        "src/hotspot/os/posix/os_posix.cpp": [
            (
                "int os::fork_and_exec(const char* cmd) {\n",
                "int os::fork_and_exec(const char* cmd) {\n"
                "#ifdef PLOZZ_TVOS\n"
                "  errno = ENOTSUP;\n"
                "  return -1;\n"
                "#else\n",
            ),
            (
                "    // Don't log, we are inside error handling\n"
                "    return -1;\n  }\n}",
                "    // Don't log, we are inside error handling\n"
                "    return -1;\n  }\n"
                "#endif\n}",
            ),
        ],
        "src/hotspot/os/posix/signals_posix.cpp": [
            (
                "#if defined(__APPLE__)\n  // lldb (gdb) installs",
                "#if defined(__APPLE__) && !defined(PLOZZ_TVOS)\n  // lldb (gdb) installs",
            ),
        ],
        "src/hotspot/os/bsd/os_bsd.cpp": [
            (
                "    Arguments::set_java_home(buf);\n    if (!set_boot_path('/', ':')) {\n"
                "        vm_exit_during_initialization",
                """#ifdef PLOZZ_TVOS
    const char* dll_dir = Arguments::get_dll_dir();
    if (strlen(dll_dir) >= 11 && strcmp(dll_dir + strlen(dll_dir) - 11, "/Frameworks") == 0) {
      if (strlen(buf) + sizeof("/DiscRuntime") > bufsize) {
        vm_exit_during_initialization("Bundled Java home path is too long", nullptr);
      }
      strcat(buf, "/DiscRuntime");
    }
#endif
    Arguments::set_java_home(buf);
    if (!set_boot_path('/', ':')) {
        vm_exit_during_initialization""",
            ),
            (
                "bool os::pd_commit_memory(char* addr, size_t size, bool exec) {\n",
                "bool os::pd_commit_memory(char* addr, size_t size, bool exec) {\n"
                "#if defined(PLOZZ_TVOS) && defined(ZERO)\n"
                '  guarantee(!exec, "tvOS Zero cannot commit executable memory");\n'
                "#endif\n",
            ),
            (
                "static char* anon_mmap(char* requested_addr, size_t bytes, bool exec) {\n",
                "static char* anon_mmap(char* requested_addr, size_t bytes, bool exec) {\n"
                "#if defined(PLOZZ_TVOS) && defined(ZERO)\n"
                '  guarantee(!exec, "tvOS Zero cannot reserve executable memory");\n'
                "#endif\n",
            ),
            (
                "static bool bsd_mprotect(char* addr, size_t size, int prot) {\n",
                "static bool bsd_mprotect(char* addr, size_t size, int prot) {\n"
                "#if defined(PLOZZ_TVOS) && defined(ZERO)\n"
                '  guarantee(!(prot & PROT_EXEC), "tvOS Zero cannot enable executable memory");\n'
                "#endif\n",
            ),
            (
                "                        bool allow_exec) {\n  int prot;",
                "                        bool allow_exec) {\n"
                "#if defined(PLOZZ_TVOS) && defined(ZERO)\n"
                '  guarantee(!allow_exec, "tvOS Zero cannot map executable file data");\n'
                "#endif\n"
                "  int prot;",
            ),
        ],
        "src/hotspot/share/runtime/os.cpp": [
            (
                "                        const char* pname, const char* fname) {\n  bool retval = false;",
                """                        const char* pname, const char* fname) {
#ifdef PLOZZ_TVOS
  if (pname != nullptr && strlen(pname) >= 11 &&
      strcmp(pname + strlen(pname) - 11, "/Frameworks") == 0) {
    if (strspn(fname, "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_") != strlen(fname)) {
      return false;
    }
    int length = jio_snprintf(buffer, buflen, "%s/PlozzBDJ%s.framework/PlozzBDJ%s", pname, fname, fname);
    return length > 0 && (size_t)length < buflen && file_exists(buffer);
  }
#endif
  bool retval = false;""",
            ),
        ],
        "src/java.base/share/classes/jdk/internal/loader/NativeLibraries.java": [
            (
                "            File libfile = new File(path, System.mapLibraryName(name));",
                """            File libfile;
            if (path.endsWith("/Frameworks")) {
                if (!name.matches("[A-Za-z0-9_]+")) {
                    throw new UnsatisfiedLinkError("Invalid bundled native library name");
                }
                String framework = "PlozzBDJ" + name;
                libfile = new File(path, framework + ".framework/" + framework);
            } else {
                libfile = new File(path, System.mapLibraryName(name));
            }""",
            ),
        ],
        "make/modules/java.base/lib/CoreLibraries.gmk": [
            (
                "$(eval $(call SetupJdkLibrary, BUILD_LIBJAVA, \\\n",
                "$(eval $(call SetupJdkLibrary, BUILD_LIBJAVA, \\\n"
                "    EXCLUDE_FILES := ProcessImpl_md.c ProcessHandleImpl_unix.c "
                "ProcessHandleImpl_macosx.c childproc.c, \\\n",
            ),
            (
                "TARGETS += $(BUILD_LIBJLI)\n",
                "# The embedded JVM uses JNI_CreateJavaVM, not the desktop launcher.\n",
            ),
        ],
        "src/java.base/macosx/native/libjava/java_props_macosx.c": [
            ("#include <objc/objc-runtime.h>", "#include <objc/runtime.h>"),
            (
                "void setProxyProperties(java_props_t *sProps) {\n",
                "void setProxyProperties(java_props_t *sProps) {\n"
                "#ifdef PLOZZ_TVOS\n"
                '    fprintf(stderr, "Plozz tvOS experiment: legacy macOS proxy properties '
                'are unavailable; system proxy selection requires java.net.useSystemProxies.\\n");\n'
                "#else\n",
            ),
            ("    CFRelease(dict);\n}", "    CFRelease(dict);\n#endif\n}"),
        ],
        "src/java.base/macosx/native/libnet/DefaultProxySelector.c": [
            ("#include <CoreServices/CoreServices.h>", "#include <CFNetwork/CFNetwork.h>"),
        ],
        "src/java.base/unix/native/libnet/NetworkInterface.c": [
            ("#include <net/if_arp.h>",
             "#ifndef PLOZZ_TVOS\n#include <net/if_arp.h>\n#endif"),
        ],
        "make/modules/java.desktop/lib/Awt2dLibraries.gmk": [
            (
                "LIBAWT_EXTRA_SRC := \\\n",
                "LIBAWT_EXTRA_SRC := \\\n"
                "    $(TOPDIR)/src/java.desktop/macosx/native/libawt_lwawt/awt/InitIDs.m \\\n",
            ),
            (
                "LIBAWT_EXTRA_HEADER_DIRS := \\\n",
                "LIBAWT_EXFILES += awt_LoadLibrary.c\n"
                "LIBAWT_EXTRA_HEADER_DIRS := \\\n"
                "    $(TOPDIR)/src/java.desktop/macosx/native/libawt_lwawt/awt \\\n",
            ),
            (
                "    LIBS_macosx := -lmlib_image \\\n"
                "        -framework Cocoa \\\n"
                "        -framework OpenGL \\\n"
                "        -framework Metal \\\n"
                "        -framework JavaRuntimeSupport \\\n"
                "        -framework ApplicationServices \\\n"
                "        -framework AudioToolbox, \\",
                "    LIBS_macosx := -lmlib_image, \\",
            ),
        ],
        "make/modules/java.base/Lib.gmk": [
            (
                "    LIBS_macosx := -framework CoreFoundation -framework CoreServices, \\",
                "    LIBS_macosx := -framework CoreFoundation -framework CFNetwork, \\",
            ),
            (
                "    TARGETS += $(BUILD_LIBOSXSECURITY)",
                "    # Desktop KeychainStore is unavailable; attempts to load it fail.\n",
            ),
        ],
    }
    for relative, replacements in patches.items():
        text = (pristine / relative).read_text()
        for original, replacement in replacements:
            text = replace_once(text, original, replacement)
        target = destination / relative
        if target.read_text() != text:
            target.write_text(text)
    process_source = Path(__file__).with_name("tvos_process.c").read_text()
    process_target = destination / "src/java.base/unix/native/libjava/tvos_process.c"
    if not process_target.exists() or process_target.read_text() != process_source:
        process_target.write_text(process_source)
    desktop_make = destination / "make/modules/java.desktop/Lib.gmk"
    text = (pristine / "make/modules/java.desktop/Lib.gmk").read_text()
    text += (
        "\n# BDToolkit owns windowing; only portable raster/image/font support is built.\n"
        "TARGETS := $(BUILD_LIBMLIB_IMAGE) $(BUILD_LIBAWT) $(BUILD_LIBLCMS) "
        "$(BUILD_LIBJAVAJPEG) $(BUILD_LIBFREETYPE)\n")
    if desktop_make.read_text() != text:
        desktop_make.write_text(text)
    loader = Path(__file__).with_name("tvos_awt.c").read_text()
    target = destination / "src/java.desktop/share/native/libawt/tvos_awt.c"
    if not target.exists() or target.read_text() != loader:
        target.write_text(loader)
    toolkit = (pristine / "src/java.desktop/macosx/native/libawt_lwawt/awt/LWCToolkit.m").read_text()
    start = "JNIEXPORT void JNICALL\nJava_sun_awt_SunToolkit_closeSplashScreen"
    end = "\n\n\n// TODO: definitely doesn't belong here"
    if toolkit.count(start) != 1 or toolkit.count(end) != 1:
        raise ValueError("Upstream splash cleanup function boundaries changed")
    splash = toolkit[toolkit.index(start):toolkit.index(end)]
    notice = toolkit[:toolkit.index("*/") + 2]
    target = destination / "src/java.desktop/share/native/libawt/tvos_splash.c"
    text = notice + "\n#include <jni.h>\n#include <dlfcn.h>\n\n" + splash + "\n"
    if not target.exists() or target.read_text() != text:
        target.write_text(text)


def stage_runtime(build_dir: Path, destination: Path) -> None:
    shutil.copytree(build_dir / "jdk/modules/java.base", destination / "modules/java.base")
    shutil.copytree(build_dir / "support/modules_libs/java.base", destination / "lib")
    shutil.copytree(build_dir / "support/modules_conf/java.base", destination / "conf")
    shutil.copytree(build_dir / "support/modules_legal/java.base", destination / "legal/java.base")
    for relative in (
        "modules/java.base/java/lang/Object.class", "modules/java.base/module-info.class",
        "lib/zero/libjvm.dylib", "lib/libjava.dylib", "lib/libjimage.dylib",
        "lib/libnet.dylib", "lib/libnio.dylib", "lib/libzip.dylib",
        "conf/security/java.security", "lib/tzdb.dat", "lib/security/cacerts",
    ):
        if not (destination / relative).is_file():
            raise RuntimeError(f"Staged Java base runtime is missing {relative}")


def build(lab, dependencies: dict[str, Path], *, runtime: bool = False,
          simulator: bool = False, bdj: bool = False, mobile: bool = False) -> Path:
    from lab import WORK
    sdk_name = ("iphonesimulator" if simulator else "iphoneos") if mobile else (
        "appletvsimulator" if simulator else "appletvos")
    lab.run("tvos-sdk", ["xcrun", "--sdk", sdk_name, "--show-sdk-path"])
    sdk = (lab.run_dir / lab.commands[-1]["log"]).read_text().strip()
    target = ("arm64-apple-ios18.0" if mobile else "arm64-apple-tvos18.0") + ("-simulator" if simulator else "")
    variant = ("iossim" if simulator else "ios") if mobile else ("tvossim" if simulator else "tvos")
    ffi_build = WORK / f"{variant}-libffi"
    ffi_install = ffi_build / "install"
    ffi_build.mkdir(exist_ok=True)
    flags = f"-target {target} -isysroot {sdk}"
    saved = dict(lab.environment)
    lab.environment.update({
        "CC": "clang", "CXX": "clang++", "CFLAGS": flags, "CXXFLAGS": flags,
        "LDFLAGS": flags,
    })
    try:
        if not (ffi_build / "Makefile").exists():
            lab.run("configure-tvos-libffi", [
                dependencies["libffi-source"] / "configure",
                "--host=aarch64-apple-darwin",
                f"--build=aarch64-apple-darwin{platform.release()}",
                "--disable-shared", "--enable-static", "--disable-docs",
                f"--prefix={ffi_install}",
            ], cwd=ffi_build)
        lab.run("compile-tvos-libffi", ["make", "-j4"], cwd=ffi_build)
        installed = ffi_install / "lib/libffi.a"
        archive = ffi_build / ".libs/libffi.a"
        install_stamp = ffi_build / ".plozz-installed-archive"
        archive_hash = hashlib.sha256(archive.read_bytes()).hexdigest()
        if (not installed.exists() or not install_stamp.exists()
                or install_stamp.read_text() != archive_hash):
            lab.run("install-isolated-tvos-libffi", ["make", "install"], cwd=ffi_build)
            install_stamp.write_text(archive_hash)
    finally:
        lab.environment = saved
    revision = dependencies["zero-source"].name
    source = WORK / f"{revision}-tvos-source"
    prepare_source(dependencies["zero-source"], source)
    build_dir = WORK / f"{revision}-{variant}-build"
    build_dir.mkdir(exist_ok=True)
    configure = [
        "bash", source / "configure", "--openjdk-target=aarch64-apple-darwin",
        "--with-jvm-variants=zero", "--enable-headless-only",
        f"--with-boot-jdk={lab.environment['JAVA_HOME']}",
        f"--with-sysroot={sdk}", f"--with-libffi={ffi_install}",
        f"--with-extra-cflags=-target {target} -DPLOZZ_TVOS=1",
        f"--with-extra-cxxflags=-target {target} -DPLOZZ_TVOS=1",
        f"--with-extra-ldflags=-target {target} -Wl,-headerpad_max_install_names",
        "--with-jvm-features=-services,-jfr,-jvmti",
        "--with-native-debug-symbols=none", "--disable-precompiled-headers",
        "--disable-warnings-as-errors",
    ]
    configuration = hashlib.sha256(json.dumps([str(value) for value in configure]).encode())
    for path in sorted((source / "make/autoconf").glob("*.m4")):
        configuration.update(path.read_bytes())
    stamp = build_dir / ".plozz-configuration"
    if not stamp.exists() or stamp.read_text() != configuration.hexdigest():
        lab.run("configure-tvos-zero", configure, cwd=build_dir)
        stamp.write_text(configuration.hexdigest())
    lab.run("compile-tvos-zero", ["make", "hotspot", "JOBS=4"],
            cwd=build_dir, timeout=1200)
    library = build_dir / "support/modules_libs/java.base/zero/libjvm.dylib"
    lab.run("verify-tvos-jvm-platform", ["otool", "-l", library])
    headers = (lab.run_dir / lab.commands[-1]["log"]).read_text()
    lab.run("verify-tvos-jvm-imports", ["nm", "-u", library])
    imports = (lab.run_dir / lab.commands[-1]["log"]).read_text()
    lab.run("verify-tvos-jvm-entrypoint", ["nm", "-gU", library])
    exports = (lab.run_dir / lab.commands[-1]["log"]).read_text()
    lab.run("verify-tvos-jvm-architecture", ["lipo", "-archs", library])
    architecture = (lab.run_dir / lab.commands[-1]["log"]).read_text()
    validate_jvm(headers, imports, exports, architecture, simulator=simulator, mobile=mobile)
    result = {
        "status": "jvm-cross-compiled-not-executed",
        "target": target,
        "library": str(library.relative_to(WORK)),
        "sha256": hashlib.sha256(library.read_bytes()).hexdigest(),
        "runtime_complete": False,
    }
    (lab.run_dir / "tvos-result.json").write_text(json.dumps(result, indent=2) + "\n")
    if runtime:
        lab.run("compile-tvos-java-base", [
            "make", "java.base-java", "java.base-libs", "java.base-gendata", "JOBS=4",
        ], cwd=build_dir, timeout=1200)
        if bdj:
            modules = ("java.datatransfer", "java.xml", "java.prefs", "java.logging",
                       "java.rmi", "java.desktop")
            lab.run("compile-tvos-bdj-modules", [
                "make", *(f"{module}-java" for module in modules),
                "java.desktop-libs", "java.desktop-gendata", "JOBS=4",
            ], cwd=build_dir, timeout=1200)
        for index, native in enumerate(sorted(
                (build_dir / "support/modules_libs/java.base").rglob("*.dylib"))):
            lab.run(f"verify-library-{index}-platform", ["otool", "-l", native])
            headers = (lab.run_dir / lab.commands[-1]["log"]).read_text()
            lab.run(f"verify-library-{index}-architecture", ["lipo", "-archs", native])
            architecture = (lab.run_dir / lab.commands[-1]["log"]).read_text()
            validate_platform(headers, architecture, simulator=simulator, mobile=mobile)
        staged = lab.run_dir / "runtime"
        stage_runtime(build_dir, staged)
        if bdj:
            for module in modules:
                shutil.copytree(build_dir / f"jdk/modules/{module}", staged / f"modules/{module}")
                for category, output in (("libs", "lib"), ("conf", "conf"),
                                         ("legal", f"legal/{module}")):
                    origin = build_dir / f"support/modules_{category}/{module}"
                    if origin.exists():
                        shutil.copytree(origin, staged / output, dirs_exist_ok=True)
        result.update({
            "status": "bdj-runtime-staged-not-executed" if bdj else "java-base-staged-not-executed",
            "runtime": str(staged.relative_to(WORK)),
            "modules": ["java.base", *modules] if bdj else ["java.base"],
        })
        (lab.run_dir / "tvos-result.json").write_text(json.dumps(result, indent=2) + "\n")
    return build_dir
