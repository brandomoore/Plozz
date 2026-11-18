#ifndef PLOZZ_TVOS_STORAGE_H
#define PLOZZ_TVOS_STORAGE_H

#include <fcntl.h>
#include <stdint.h>
#include <sys/stat.h>
#include <sys/uio.h>
#include "jni.h"
#include "jni_util.h"

static jboolean plozz_storage_active(JNIEnv *env) {
    jclass type = (*env)->FindClass(env, "java/io/PlozzStorageBudget");
    if (!type) return JNI_TRUE;
    jmethodID method = (*env)->GetStaticMethodID(env, type, "isActive", "()Z");
    jboolean active = method ? (*env)->CallStaticBooleanMethod(env, type, method) : JNI_TRUE;
    (*env)->DeleteLocalRef(env, type);
    return active || (*env)->ExceptionCheck(env);
}

static jboolean plozz_storage_charge(JNIEnv *env, jlong bytes) {
    jclass type = (*env)->FindClass(env, "java/io/PlozzStorageBudget");
    if (!type) return JNI_FALSE;
    jmethodID method = (*env)->GetStaticMethodID(env, type, "reserve", "(J)V");
    if (method) (*env)->CallStaticVoidMethod(env, type, method, bytes);
    (*env)->DeleteLocalRef(env, type);
    return !(*env)->ExceptionCheck(env);
}

/* Charge positions as well as writes, without refunds. This bounds sparse growth
 * even when another Java thread changes the descriptor's position concurrently. */
static jboolean plozz_storage_reserve(JNIEnv *env, int fd, jlong bytes) {
    struct stat status;
    int flags;
    if (fd >= 0 && fd <= 2) return JNI_TRUE;
    if (fstat(fd, &status) != 0 || (flags = fcntl(fd, F_GETFL)) < 0) {
        JNU_ThrowIOExceptionWithLastError(env, "Disc storage descriptor unavailable");
        return JNI_FALSE;
    }
    if (!S_ISREG(status.st_mode) || (flags & O_ACCMODE) == O_RDONLY) return JNI_TRUE;
    return plozz_storage_charge(env, bytes);
}

static jboolean plozz_storage_range(JNIEnv *env, int fd, jlong offset, jlong length) {
    if (offset < 0 || length < 0 || offset > INT64_MAX - length) {
        JNU_ThrowIOException(env, "Invalid disc storage range");
        return JNI_FALSE;
    }
    return plozz_storage_reserve(env, fd, offset + length);
}

static jboolean plozz_storage_vectors(JNIEnv *env, int fd, struct iovec *iov, int count) {
    jlong total = 0;
    for (int i = 0; i < count; i++) {
        if (iov[i].iov_len > (uint64_t)(INT64_MAX - total)) {
            JNU_ThrowIOException(env, "Invalid disc storage vector");
            return JNI_FALSE;
        }
        total += iov[i].iov_len;
    }
    return plozz_storage_reserve(env, fd, total);
}

#endif
