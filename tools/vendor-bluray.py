#!/usr/bin/env python3
"""Import pinned libbluray sources and reproducible embedded-runtime adaptations."""
import argparse
import hashlib
import json
from pathlib import Path, PurePosixPath
import tarfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("archive", type=Path)
    parser.add_argument("--jni-archive", type=Path)
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    pin = json.loads((root / "tools/disc-menu-lab/dependencies.json").read_text())["libbluray"]
    if hashlib.sha256(args.archive.read_bytes()).hexdigest() != pin["sha256"]:
        raise SystemExit("libbluray archive checksum mismatch")
    destination = root / "Vendor/Libbluray"
    with tarfile.open(args.archive) as archive:
        for member in archive.getmembers():
            path = PurePosixPath(member.name)
            if not member.isfile() or path.parts[0] != pin["root"]:
                continue
            relative = PurePosixPath(*path.parts[1:])
            if ".." in relative.parts:
                raise SystemExit("Invalid archive path")
            selected = (
                str(relative) == "COPYING"
                or str(relative) == "contrib/libudfread/COPYING"
                or (str(relative).startswith("src/") and relative.suffix in (".c", ".h"))
                or (str(relative).startswith("contrib/libudfread/src/") and relative.suffix in (".c", ".h"))
            )
            if not selected:
                continue
            source = archive.extractfile(member)
            if source is None:
                raise SystemExit("Missing archive member")
            output = destination / str(relative)
            output.parent.mkdir(parents=True, exist_ok=True)
            output.write_bytes(source.read())
        version = archive.extractfile(f"{pin['root']}/src/libbluray/bluray-version.h.in")
        if version is None:
            raise SystemExit("Missing version template")
        text = version.read().decode()
        for name, value in (("MAJOR", "1"), ("MINOR", "5"), ("MICRO", "0")):
            text = text.replace(f"@BLURAY_VERSION_{name}@", value)
        (destination / "src/libbluray/bluray-version.h").write_text(text)
    if args.jni_archive:
        jdk = json.loads((root / "tools/disc-menu-lab/dependencies.json").read_text())["zero-source"]
        if hashlib.sha256(args.jni_archive.read_bytes()).hexdigest() != jdk["sha256"]:
            raise SystemExit("OpenJDK archive checksum mismatch")
        headers = destination / "jni"
        headers.mkdir(exist_ok=True)
        with tarfile.open(args.jni_archive) as archive:
            for relative, name in [
                ("src/java.base/share/native/include/jni.h", "jni.h"),
                ("src/java.base/unix/native/include/jni_md.h", "jni_md.h"),
                ("LICENSE", "LICENSE"), ("ADDITIONAL_LICENSE_INFO", "ADDITIONAL_LICENSE_INFO"),
            ]:
                member = archive.extractfile(f"{jdk['root']}/{relative}")
                if member is None:
                    raise SystemExit(f"Missing OpenJDK member: {relative}")
                (headers / name).write_bytes(member.read())
        (headers / "UPSTREAM.json").write_text(json.dumps(jdk, indent=2) + "\n")
    bdj = destination / "src/libbluray/bdj/bdj.c"
    text = bdj.read_text()
    guard = "#if defined(__APPLE__) && !defined(HAVE_BDJ_J2ME)"
    if text.count(guard) != 7:
        raise SystemExit("Unexpected desktop Java discovery guards")
    text = text.replace(guard, guard + " && !defined(PLOZZ_EMBEDDED_BDJ)")
    before = 'static const char * const jvm_dir[]  = {"jre/lib/server",\n                                            "lib/server"};'
    if text.count(before) != 1:
        raise SystemExit("Unexpected JVM search paths")
    text = text.replace(before, 'static const char * const jvm_dir[] = {"lib/zero"};')
    text = text.replace('str_dup   ("-Xms256M")', 'str_dup   ("-Xms16M")')
    text = text.replace('str_dup   ("-Xmx256M")', 'str_dup   ("-Xmx128M")')
    before = '    option[n++].optionString = str_dup   ("-Xss2048k");'
    if text.count(before) != 1:
        raise SystemExit("Unexpected JVM options")
    text = text.replace(before, before + """
    option[n++].optionString = str_dup("-Djava.security.manager=allow");
    option[n++].optionString = str_dup("-XX:+UseSerialGC");
    option[n++].optionString = str_dup("-XX:ActiveProcessorCount=2");
    option[n++].optionString = str_dup("-XX:MaxMetaspaceSize=96M");
    option[n++].optionString = str_dup("-XX:MaxDirectMemorySize=32M");
    option[n++].optionString = str_printf("-Djava.home=%s", java_home);
    option[n++].optionString = str_printf("-Djava.io.tmpdir=%s", plozz_bdj_cache_root());
""")
    text = '#include "bdj_runtime.h"\n' + text
    before = '                BD_DEBUG(DBG_BDJ | DBG_CRIT, "Failed to shutdown BD-J (uncaught exception)\\n");'
    if text.count(before) != 1:
        raise SystemExit("Unexpected Java shutdown exception handler")
    text = text.replace(before, before + "\n                plozz_bdj_quarantine();")
    before = "    if (!bdj_register_native_methods(env)) {"
    if text.count(before) != 1:
        raise SystemExit("Unexpected Java native registration")
    text = text.replace(before, """    if (plozz_bdj_is_quarantined()) {
        BD_DEBUG(DBG_BDJ | DBG_CRIT, "Java runtime is quarantined after incomplete shutdown\\n");
        return 0;
    }

""" + before)
    before = """            (*env)->DeleteLocalRef(env, shutdown_class);
        }"""
    if text.count(before) != 1:
        raise SystemExit("Unexpected Java shutdown method lookup")
    text = text.replace(before, """            (*env)->DeleteLocalRef(env, shutdown_class);
        } else {
            plozz_bdj_quarantine();
        }""")
    bdj.write_text(text)
    navigation = destination / "src/libbluray/bluray.c"
    text = navigation.read_text()
    poll = """    if (len < 1) {
        /* just polled events ? */
        return 0;
    }

"""
    read = "    int bytes = _bd_read_locked(bd, buf, len);"
    if text.count(poll) != 1 or text.count(read) != 1:
        raise SystemExit("Unexpected navigation polling layout")
    # Event-only polls must still deliver Java's deferred end-of-playlist event.
    text = text.replace(poll, "").replace(read, poll + read)
    navigation.write_text(text)
    (destination / "UPSTREAM.json").write_text(json.dumps(pin, indent=2) + "\n")
    notices = (
        "libbluray 1.5.0 and bundled libudfread\n"
        f"Source archive: {pin['url']}\n"
        "Plozz build adaptations: Vendor/Libbluray and Sources/DiscNavigation.\n\n"
        "BD-J runtime: OpenJDK Zero, with application-specific interpreter and AWT\n"
        "adaptations in tools/disc-menu-lab/tvos.py and tools/build-disc-runtime.py.\n"
        "Pinned source archives and checksums: tools/disc-menu-lab/dependencies.json.\n"
        "OpenJDK and its component license notices are retained in DiscRuntime/legal.\n"
        "ASM bytecode support retains its notice in DiscRuntime/legal/asm/LICENSE.txt.\n"
        "The bundled DejaVu font license is retained in DiscRuntime/legal/dejavu/LICENSE.\n"
        "JNI header notices and the OpenJDK Classpath exception are in Vendor/Libbluray/jni.\n\n"
        + (destination / "COPYING").read_text()
        + "\n\nBundled libudfread:\n\n"
        + (destination / "contrib/libudfread/COPYING").read_text()
    )
    (root / "App/Resources/LibblurayNotices.txt").write_text(notices)


if __name__ == "__main__":
    main()
