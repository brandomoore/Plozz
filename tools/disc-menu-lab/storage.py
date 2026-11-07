"""Reproducible write-budget hooks for the pinned Apple Zero runtime."""
from pathlib import Path
from tvos import replace_once


def prepare_storage(pristine: Path, destination: Path) -> None:
    patches = {
        "share/native/libjava/io_util.c": [
            ("    if (append == JNI_TRUE) {\n        n = IO_Append(fd, &c, 1);",
             "    if (!plozz_storage_reserve(env, fd, 1)) return;\n"
             "    if (append == JNI_TRUE) {\n        n = IO_Append(fd, &c, 1);"),
            ("    if (len == 0) {\n        return;\n    } else if (len > BUF_SIZE) {",
             "    if (len == 0) {\n        return;\n    }\n"
             "    if (!plozz_storage_reserve(env, getFD(env, this, fid), len)) return;\n"
             "    if (len > BUF_SIZE) {"),
        ],
        "share/native/libjava/RandomAccessFile.c": [
            ("    } else if (IO_Lseek(fd, pos, SEEK_SET) == -1) {",
             "    } else if (!plozz_storage_reserve(env, fd, pos)) {\n        return;\n"
             "    } else if (IO_Lseek(fd, pos, SEEK_SET) == -1) {"),
            ("    if ((cur = IO_Lseek(fd, 0L, SEEK_CUR)) == -1) goto fail;",
             "    if (!plozz_storage_reserve(env, fd, newLength)) return;\n"
             "    if ((cur = IO_Lseek(fd, 0L, SEEK_CUR)) == -1) goto fail;"),
        ],
        "unix/native/libnio/ch/UnixFileDispatcherImpl.c": [
            ("    return convertReturnVal(env, write(fd, buf, len), JNI_FALSE);",
             "    if (!plozz_storage_reserve(env, fd, len)) return IOS_THROWN;\n"
             "    return convertReturnVal(env, write(fd, buf, len), JNI_FALSE);"),
            ("    return convertReturnVal(env, pwrite64(fd, buf, len, offset), JNI_FALSE);",
             "    if (!plozz_storage_range(env, fd, offset, len)) return IOS_THROWN;\n"
             "    return convertReturnVal(env, pwrite64(fd, buf, len, offset), JNI_FALSE);"),
            ("    return convertLongReturnVal(env, writev(fd, iov, len), JNI_FALSE);",
             "    if (!plozz_storage_vectors(env, fd, iov, len)) return IOS_THROWN;\n"
             "    return convertLongReturnVal(env, writev(fd, iov, len), JNI_FALSE);"),
            ("        result = lseek64(fd, offset, SEEK_SET);",
             "        if (!plozz_storage_reserve(env, fd, offset)) return IOS_THROWN;\n"
             "        result = lseek64(fd, offset, SEEK_SET);"),
            ("    return handle(env,\n                  ftruncate64(fdval(env, fdo), size),",
             "    if (!plozz_storage_reserve(env, fdval(env, fdo), size)) return IOS_THROWN;\n"
             "    return handle(env,\n                  ftruncate64(fdval(env, fdo), size),"),
            ("    mapAddress = mmap64(",
             "    if (prot != sun_nio_ch_UnixFileDispatcherImpl_MAP_RO &&\n"
             "        !plozz_storage_range(env, fd, off, len)) return IOS_THROWN;\n"
             "    mapAddress = mmap64("),
        ],
        "unix/native/libnio/fs/UnixNativeDispatcher.c": [
            ("    RESTARTABLE(write((int)fd, bufp, (size_t)nbytes), n);",
             "    if (!plozz_storage_reserve(env, fd, nbytes)) return -1;\n"
             "    RESTARTABLE(write((int)fd, bufp, (size_t)nbytes), n);"),
            ("#ifdef __linux__\n    res = fsetxattr(",
             "    if (!plozz_storage_charge(env, (jlong)valueLen + strlen(name) + 1)) return;\n"
             "#ifdef __linux__\n    res = fsetxattr("),
        ],
        "unix/native/libnio/fs/UnixFileSystem.c": [
            ("            RESTARTABLE(write((int)dst, bufp, len), n);",
             "            if (!plozz_storage_reserve(env, dst, len)) return;\n"
             "            RESTARTABLE(write((int)dst, bufp, len), n);"),
        ],
        # Use the existing bounded-buffer fallback rather than a copy syscall
        # whose source can grow after a size check.
        "macosx/native/libnio/fs/BsdFileSystem.c": [
            ("    copyfile_state_t state;",
             "    if (plozz_storage_active(env)) return IOS_UNSUPPORTED;\n"
             "    copyfile_state_t state;"),
        ],
        "macosx/native/libnio/fs/BsdNativeDispatcher.c": [
            ("    int ret = clonefile(src, dst, flags);",
             "    if (plozz_storage_active(env)) {\n"
             "        if (!(*env)->ExceptionCheck(env)) throwUnixException(env, ENOTSUP);\n"
             "        return -1;\n    }\n"
             "    int ret = clonefile(src, dst, flags);"),
        ],
    }
    base = "src/java.base/"
    header = Path(__file__).with_name("tvos_storage.h").read_text()
    for relative, replacements in patches.items():
        text = (pristine / base / relative).read_text()
        for before, after in replacements:
            text = replace_once(text, before, after)
        text = '#include "tvos_storage.h"\n' + text
        target = destination / base / relative
        if target.read_text() != text:
            target.write_text(text)
        include = target.with_name("tvos_storage.h")
        if not include.exists() or include.read_text() != header:
            include.write_text(header)
    target = destination / base / "share/classes/java/io/PlozzStorageBudget.java"
    text = Path(__file__).with_name("PlozzStorageBudget.java").read_text()
    if not target.exists() or target.read_text() != text:
        target.write_text(text)
