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
    option[n++].optionString = str_dup("-XX:+UnlockDiagnosticVMOptions");
    option[n++].optionString = str_dup("-XX:-ImplicitNullChecks");
    option[n++].optionString = str_dup("-XX:+ReduceSignalUsage");
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
    before = """            (*bdjava->jvm)->AttachCurrentThread(bdjava->jvm, (void**)&env, NULL);
            attach = 1;
        }

        if (_get_method(env, &shutdown_class"""
    if text.count(before) != 1:
        raise SystemExit("Unexpected Java shutdown attachment")
    text = text.replace(before, """            if ((*bdjava->jvm)->AttachCurrentThread(bdjava->jvm, (void**)&env, NULL) != JNI_OK) {
                BD_DEBUG(DBG_BDJ | DBG_CRIT, "Cannot attach for Java shutdown; retaining disc\\n");
                plozz_bdj_quarantine();
                return;
            }
            attach = 1;
        }

        if (_get_method(env, &shutdown_class""")
    before = """    if (bdjava->h_libjvm) {
        dl_dlclose(bdjava->h_libjvm);
    }"""
    if text.count(before) != 1:
        raise SystemExit("Unexpected Java native lifetime boundary")
    text = text.replace(before, """    /* In-flight JNI calls may still own this context after failed shutdown. */
    if (plozz_bdj_is_quarantined()) {
        return;
    }

""" + before)
    bdj.write_text(text)
    navigation = destination / "src/libbluray/bluray.c"
    text = navigation.read_text()
    text = '#include "bdj_runtime.h"\n' + text
    before = "    BDJAVA         *bdjava;"
    if text.count(before) != 1:
        raise SystemExit("Unexpected Java context member")
    text = text.replace(before, before + "\n    int             bdj_quarantined;")
    before = """        bdj_close(bd->bdjava);
        bd->bdjava = NULL;"""
    if text.count(before) != 1:
        raise SystemExit("Unexpected Java context shutdown")
    text = text.replace(before, """        bdj_close(bd->bdjava);
        bd->bdj_quarantined = plozz_bdj_is_quarantined();
        bd->bdjava = NULL;""")
    before = """    _close_bdj(bd);

    _close_m2ts(&bd->st0);"""
    if text.count(before) != 1:
        raise SystemExit("Unexpected disc lifetime boundary")
    text = text.replace(before, """    _close_bdj(bd);
    /* A surviving JNI call may still reference any part of this disc. */
    if (bd->bdj_quarantined) {
        BD_DEBUG(DBG_BLURAY | DBG_CRIT, "Retaining quarantined disc until process exit\\n");
        return;
    }

    _close_m2ts(&bd->st0);""")
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
    text = adapt_presentation_marks(text)
    navigation.write_text(text)
    (destination / "UPSTREAM.json").write_text(json.dumps(pin, indent=2) + "\n")
    notices = (
        "libbluray 1.5.0 and bundled libudfread\n"
        f"Source archive: {pin['url']}\n"
        "Plozz build adaptations: Vendor/Libbluray and Sources/DiscNavigation.\n\n"
        "Distribution builds include native disc navigation, not a Java runtime.\n"
        "Experimental local Debug builds may opt into OpenJDK Zero with interpreter and AWT\n"
        "adaptations in tools/disc-menu-lab/tvos.py and tools/build-disc-runtime.py.\n"
        "Pinned source archives and checksums: tools/disc-menu-lab/dependencies.json.\n"
        "In those experimental builds, runtime notices are retained in DiscRuntime/legal.\n"
        "Its primary GPLv2 license, additional-license information and assembly exception\n"
        "are retained in DiscRuntime/legal/openjdk.\n"
        "ASM bytecode support retains its notice in DiscRuntime/legal/asm/LICENSE.txt.\n"
        "The statically linked libffi license is retained in DiscRuntime/legal/libffi/LICENSE.\n"
        "The bundled DejaVu font license is retained in DiscRuntime/legal/dejavu/LICENSE.\n"
        "JNI header notices and the OpenJDK Classpath exception are in Vendor/Libbluray/jni.\n\n"
        + (destination / "COPYING").read_text()
        + "\n\nBundled libudfread:\n\n"
        + (destination / "contrib/libudfread/COPYING").read_text()
    )
    (root / "App/Resources/LibblurayNotices.txt").write_text(notices)


def adapt_presentation_marks(text):
    """Keep authored cues on the external renderer's clock, not its byte reader."""
    start = text.index("static void _find_next_playmark(BLURAY *bd)")
    end = text.index("\n/*\n * seeking and current position", start)
    text = text[:start] + """static void _find_next_playmark_at_time(BLURAY *bd, uint64_t time)
{
    unsigned ii;
    bd->next_mark = -1;
    bd->next_mark_pos = (uint64_t)-1;
    for (ii = 0; ii < bd->title->mark_list.count; ii++) {
        if (bd->title->mark_list.mark[ii].title_time > time) {
            bd->next_mark = ii;
            bd->next_mark_pos = (uint64_t)bd->title->mark_list.mark[ii].title_pkt * 192L;
            break;
        }
    }
}

static void _find_next_playmark(BLURAY *bd)
{
    unsigned ii;
    if (bd->app_scr && bd->st0.clip) {
        const NAV_CLIP *clip = bd->st0.clip;
        uint64_t time = bd_psr_read(bd->regs, PSR_TIME);
        _find_next_playmark_at_time(bd, clip->title_time +
                                   (time > clip->in_time ? time - clip->in_time : 0));
    } else {
        bd->next_mark = -1;
        bd->next_mark_pos = (uint64_t)-1;
        for (ii = 0; ii < bd->title->mark_list.count; ii++) {
            uint64_t pos = (uint64_t)bd->title->mark_list.mark[ii].title_pkt * 192L;
            if (pos > bd->s_pos) {
                bd->next_mark = ii;
                bd->next_mark_pos = pos;
                break;
            }
        }
    }

    _update_chapter_psr(bd);
}

static void _emit_playmark(BLURAY *bd)
{
    _queue_event(bd, BD_EVENT_PLAYMARK, bd->next_mark);
    _bdj_event(bd, BDJ_EVENT_MARK, bd->next_mark);
    bd->next_mark++;
    if ((unsigned)bd->next_mark < bd->title->mark_list.count) {
        bd->next_mark_pos = (uint64_t)bd->title->mark_list.mark[bd->next_mark].title_pkt * 192L;
    } else {
        bd->next_mark = -1;
        bd->next_mark_pos = (uint64_t)-1;
    }
}

static void _playmark_reached(BLURAY *bd)
{
    while (bd->next_mark >= 0 && bd->s_pos > bd->next_mark_pos) {

        BD_DEBUG(DBG_BLURAY, "PlayMark %d reached (%" PRIu64 ")\\n", bd->next_mark, bd->next_mark_pos);

        _emit_playmark(bd);
    };

    /* chapter tracking */
    _update_chapter_psr(bd);
}
""" + text[end:]
    before = """        clip = nav_time_search(bd->title, (uint32_t)tick, &clip_pkt, &out_pkt);

        _seek_internal(bd, clip, out_pkt, clip_pkt);"""
    if text.count(before) != 1:
        raise SystemExit("Unexpected presentation time seek layout")
    text = text.replace(before, """        clip = nav_time_search(bd->title, (uint32_t)tick, &clip_pkt, &out_pkt);

        if (_seek_internal(bd, clip, out_pkt, clip_pkt) >= 0 && bd->app_scr) {
            /* A keyframe can precede both the requested time and a skipped mark. */
            _find_next_playmark_at_time(bd, tick);
        }""")
    before = """    bd->app_scr = 1;
    _set_scr(bd, pts);"""
    if text.count(before) != 1:
        raise SystemExit("Unexpected external presentation clock layout")
    return text.replace(before, before + """
    /* External renderers advance presentation without reading this stream. */
    if (pts >= 0 && bd->title && bd->st0.clip) {
        const NAV_CLIP *clip = bd->st0.clip;
        uint64_t tick = (uint64_t)pts >> 1;
        if (tick >= clip->in_time && tick <= clip->out_time) {
            uint64_t title_time = tick - clip->in_time + clip->title_time;
            while (bd->next_mark >= 0 &&
                   bd->title->mark_list.mark[bd->next_mark].title_time <= title_time) {
                _emit_playmark(bd);
            }
        }
    }""")


if __name__ == "__main__":
    main()
