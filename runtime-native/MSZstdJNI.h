#ifndef MSL_ZSTD_JNI_H
#define MSL_ZSTD_JNI_H
#include <jni.h>

/* Named entry point permits a source-built library linked into the iOS app. */
JNIEXPORT jint JNICALL JNI_OnLoad_mslzstd(JavaVM *vm, void *reserved);
JNIEXPORT void JNICALL JNI_OnUnload_mslzstd(JavaVM *vm, void *reserved);

/* Call only after source/native operations have drained, before destroying the VM.
 * Closes abandoned idle contexts and drops the parent codec's class references.
 * Returns JNI_ERR without changing state if any native operation is still active.
 */
int msl_zstd_shutdown(JNIEnv *env);
#endif
