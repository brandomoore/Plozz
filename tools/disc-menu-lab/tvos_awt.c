#include <jni.h>
#include <string.h>
#include "jni_util.h"

JNIEXPORT JavaVM *jvm;

JNIEXPORT jint JNICALL JNI_OnLoad(JavaVM *vm, void *reserved) {
    (void)reserved;
    JNIEnv *env = NULL;
    if ((*vm)->GetEnv(vm, (void **)&env, JNI_VERSION_1_8) != JNI_OK) return JNI_ERR;
    jclass system = (*env)->FindClass(env, "java/lang/System");
    if (!system) return JNI_ERR;
    jmethodID getter = (*env)->GetStaticMethodID(
        env, system, "getProperty", "(Ljava/lang/String;)Ljava/lang/String;");
    if (!getter) return JNI_ERR;
    jstring key = (*env)->NewStringUTF(env, "awt.toolkit");
    if (!key) return JNI_ERR;
    jstring value = (jstring)(*env)->CallStaticObjectMethod(env, system, getter, key);
    if ((*env)->ExceptionCheck(env) || !value) return JNI_ERR;
    const char *toolkit = (*env)->GetStringUTFChars(env, value, NULL);
    if (!toolkit) return JNI_ERR;
    int supported = strcmp(toolkit, "java.awt.BDToolkit") == 0;
    (*env)->ReleaseStringUTFChars(env, value, toolkit);
    if (!supported) {
        JNU_ThrowByName(env, "java/lang/UnsupportedOperationException",
                       "The tvOS AWT port supports only libbluray BDToolkit");
        return JNI_ERR;
    }
    jvm = vm;
    return JNI_VERSION_1_8;
}

JNIEXPORT jboolean JNICALL AWTIsHeadless(void) {
    /* BDToolkit supplies a real offscreen display without a desktop window server. */
    return JNI_FALSE;
}
