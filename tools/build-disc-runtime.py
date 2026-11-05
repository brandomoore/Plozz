#!/usr/bin/env python3
"""Build the pinned interpreter and offscreen Java libraries for an Apple target."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import sys

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools/disc-menu-lab"))
from lab import Lab, WORK
import tvos
import tvos_bdj


def source_fingerprint():
    digest = hashlib.sha256()
    for path in ["tools/build-disc-runtime.py", "tools/disc-menu-lab/dependencies.json",
                 "tools/disc-menu-lab/tvos.py", "tools/disc-menu-lab/tvos_bdj.py"]:
        digest.update(path.encode())
        digest.update((ROOT / path).read_bytes())
    return digest.hexdigest()


def harden_bluray(bluray):
    security = bluray / "src/libbluray/bdj/java/org/videolan/BDJSecurityManager.java"
    text = security.read_text()
    text = tvos.replace_once(text, """        String enable = System.getProperty("bluray.network.connected");
        if (enable != null && enable.equals("YES"))
            return;
        deny(perm);""", "        deny(perm);")
    text = tvos.replace_once(text, """                 urlPermission.isInstance(perm)) {
            logger.info("grant " + perm);
            return;""", """                 urlPermission.isInstance(perm)) {
            deny(perm);
            return;""")
    security.write_text(text)
    mount = bluray / "src/libbluray/bdj/java/org/videolan/MountManager.java"
    text = mount.read_text()
    text = tvos.replace_once(text, "    private static Map mountPoints = new HashMap();",
                             """    private static Map mountPoints = new HashMap();
    private static long mountedBytes;
    private static int mountedEntries;""")
    text = tvos.replace_once(text, "            mountPoints.clear();",
                             """            mountPoints.clear();
            mountedBytes = 0;
            mountedEntries = 0;""")
    text = tvos.replace_once(text, """                    File out = new File(mountPoint.getMountPoint() + File.separator + entry.getName());""",
                             """                    if (++mountedEntries > 4096) {
                        throw new IOException("Disc archive entry limit exceeded");
                    }
                    File out = new File(mountPoint.getMountPoint() + File.separator + entry.getName());
                    String root = new File(mountPoint.getMountPoint()).getCanonicalPath() + File.separator;
                    if (!out.getCanonicalPath().startsWith(root)) {
                        throw new IOException("Disc archive entry escapes its mount");
                    }""")
    text = tvos.replace_once(text, """                            outStream.write(buffer, 0, length);""",
                             """                            mountedBytes += length;
                            if (mountedBytes > 128L * 1024 * 1024) {
                                throw new IOException("Disc archive expansion limit exceeded");
                            }
                            outStream.write(buffer, 0, length);""")
    mount.write_text(text)
    lifecycle = bluray / "src/libbluray/bdj/java/org/videolan/Libbluray.java"
    text = lifecycle.read_text()
    text = tvos.replace_once(text, """                               String persistentRoot, String budaRoot) {

        initOnce();""", """                               String persistentRoot, String budaRoot) {
        if (runtimeQuarantined) {
            throw new IllegalStateException("Previous disc did not terminate; restart the application");
        }
        initOnce();""")
    text = tvos.replace_once(text, """    /* called only from native code */
    private static void shutdown() {""", """    private static boolean runtimeQuarantined;

    private static boolean hasDiscThreads() {
        for (Thread thread : Thread.getAllStackTraces().keySet()) {
            if (!thread.isAlive() || thread == Thread.currentThread()) {
                continue;
            }
            if (thread.getContextClassLoader() instanceof BDJClassLoader) {
                return true;
            }
            for (ThreadGroup group = thread.getThreadGroup(); group != null; group = group.getParent()) {
                if (group instanceof BDJThreadGroup) {
                    return true;
                }
            }
        }
        return false;
    }

    /* called only from native code */
    private static void shutdown() {""")
    text = tvos.replace_once(text, """        try {
            stopTitle(true);""", """        runtimeQuarantined = true;
        boolean teardownComplete = false;
        try {
            stopTitle(true);""")
    text = tvos.replace_once(text, """            /* all Xlet contexts (and threads) should be terminated now */""",
                             """            // Never remove the disc policy while an Xlet still executes.
            if (hasDiscThreads()) {
                throw new IllegalStateException("Disc threads survived title shutdown");
            }""")
    text = tvos.replace_once(text, """            FontFactory.unloadDiscFonts();
        } catch""", """            FontFactory.unloadDiscFonts();
            teardownComplete = true;
        } catch""")
    text = tvos.replace_once(text, """            BDJAppProxy.cleanup();
            CacheDir.remove();""", """            BDJAppProxy.cleanup();
            CacheDir.remove();
            runtimeQuarantined = !teardownComplete || hasDiscThreads();""")
    text = tvos.replace_once(text, """        nativePointer = 0;
        titleInfos = null;""", """        nativePointer = 0;
        if (runtimeQuarantined) {
            throw new IllegalStateException("Disc runtime quarantined after incomplete shutdown");
        }
        titleInfos = null;""")
    lifecycle.write_text(text)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--sdk", required=True, choices=[
        "appletvos", "appletvsimulator", "iphoneos", "iphonesimulator"])
    args = parser.parse_args()
    fingerprint = source_fingerprint()
    simulator = args.sdk.endswith("simulator")
    mobile = args.sdk.startswith("iphone")
    lab = Lab()
    dependencies = lab.dependencies(zero=True, bdj=True)
    build = tvos.build(lab, dependencies, runtime=True, simulator=simulator, bdj=True, mobile=mobile)
    source = WORK / f"{dependencies['zero-source'].name}-tvos-source"
    bluray = lab.run_dir / "libbluray-source"
    tvos_bdj.prepare_bluray(dependencies["libbluray"], bluray, source,
                           build / "support/modules_libs/java.desktop")
    harden_bluray(bluray)
    jars = lab.run_dir / "runtime/jars"
    jars.mkdir()
    java = Path(lab.environment["JAVA_HOME"]) / "bin"
    lab.run("compile-app-bdj-jars", [
        "ant", "-f", bluray / "src/libbluray/bdj/build.xml",
        f"-Dbuild={lab.run_dir / 'bdj-classes'}", f"-Ddist={jars}",
        "-Dbootclasspath=", "-Dsrc_awt=:java-j2se:java-build-support",
        f"-Djavac_path={java / 'javac'}", "-Djavac_arg=-Xlint:-removal",
        "-Dversion=j2se-1.5.0", "-Djava_version_asm=1.8", "-Djava_version_bdj=1.8",
    ])
    runtime = lab.run_dir / "runtime"
    for module in (runtime / "modules").iterdir():
        legal = source / "src" / module.name / "share/legal"
        if legal.is_dir():
            shutil.copytree(legal, runtime / "legal" / module.name, dirs_exist_ok=True)
    for name, notice in (("libbluray", bluray / "COPYING"),
                         ("asm", bluray / "contrib/asm/LICENSE.txt")):
        destination = runtime / "legal" / name
        destination.mkdir()
        shutil.copy2(notice, destination / notice.name)
    shutil.copytree(dependencies["menu-fonts"] / "ttf", runtime / "lib/fonts")
    (runtime / "legal/dejavu").mkdir()
    shutil.copy2(dependencies["menu-fonts"] / "LICENSE", runtime / "legal/dejavu/LICENSE")
    for index, library in enumerate(sorted((runtime / "lib").rglob("*.dylib"))):
        lab.run(f"verify-app-library-{index}", ["otool", "-l", library])
        headers = (lab.run_dir / lab.commands[-1]["log"]).read_text()
        lab.run(f"verify-app-architecture-{index}", ["lipo", "-archs", library])
        tvos.validate_platform(headers, (lab.run_dir / lab.commands[-1]["log"]).read_text(),
                               simulator=simulator, mobile=mobile)
    receipt = ROOT / ".build/disc-runtime" / f"{args.sdk}.json"
    receipt.parent.mkdir(parents=True, exist_ok=True)
    receipt.write_text(json.dumps({
        "sdk": args.sdk, "runtime": str(runtime), "sourceFingerprint": fingerprint
    }, indent=2) + "\n")
    print(f"Runtime: {runtime}", flush=True)


if __name__ == "__main__":
    main()
