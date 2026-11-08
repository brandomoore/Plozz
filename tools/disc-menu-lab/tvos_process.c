#include "jni_util.h"
#include "java_lang_ProcessImpl.h"
#include "java_lang_ProcessHandleImpl.h"
#include "java_lang_ProcessHandleImpl_Info.h"

static void unsupported(JNIEnv *env) {
    JNU_ThrowByName(env, "java/lang/UnsupportedOperationException",
                   "External process operations are unavailable in the tvOS runtime");
}

JNIEXPORT void JNICALL Java_java_lang_ProcessImpl_init(JNIEnv *env, jclass type) {
    unsupported(env);
}

JNIEXPORT jint JNICALL Java_java_lang_ProcessImpl_forkAndExec(
    JNIEnv *env, jobject object, jint mode, jbyteArray helper, jbyteArray program,
    jbyteArray arguments, jint argc, jbyteArray environment, jint envc,
    jbyteArray directory, jintArray descriptors, jboolean redirect) {
    unsupported(env);
    return -1;
}

JNIEXPORT void JNICALL Java_java_lang_ProcessHandleImpl_initNative(JNIEnv *env, jclass type) {
    unsupported(env);
}

JNIEXPORT jint JNICALL Java_java_lang_ProcessHandleImpl_waitForProcessExit0(
    JNIEnv *env, jclass type, jlong pid, jboolean reap) {
    unsupported(env);
    return -1;
}

JNIEXPORT jlong JNICALL Java_java_lang_ProcessHandleImpl_getCurrentPid0(JNIEnv *env, jclass type) {
    unsupported(env);
    return -1;
}

JNIEXPORT jlong JNICALL Java_java_lang_ProcessHandleImpl_parent0(
    JNIEnv *env, jclass type, jlong pid, jlong start) {
    unsupported(env);
    return -1;
}

JNIEXPORT jint JNICALL Java_java_lang_ProcessHandleImpl_getProcessPids0(
    JNIEnv *env, jclass type, jlong pid, jlongArray pids, jlongArray parents, jlongArray starts) {
    unsupported(env);
    return -1;
}

JNIEXPORT jboolean JNICALL Java_java_lang_ProcessHandleImpl_destroy0(
    JNIEnv *env, jclass type, jlong pid, jlong start, jboolean force) {
    unsupported(env);
    return JNI_FALSE;
}

JNIEXPORT jlong JNICALL Java_java_lang_ProcessHandleImpl_isAlive0(
    JNIEnv *env, jclass type, jlong pid) {
    unsupported(env);
    return -1;
}

JNIEXPORT void JNICALL Java_java_lang_ProcessHandleImpl_00024Info_initIDs(JNIEnv *env, jclass type) {
    unsupported(env);
}

JNIEXPORT void JNICALL Java_java_lang_ProcessHandleImpl_00024Info_info0(
    JNIEnv *env, jobject object, jlong pid) {
    unsupported(env);
}
