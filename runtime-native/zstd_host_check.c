/* Authored host-only harness: prove JVM discovery of the linked named JNI library. */
#include "MSZstdJNI.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static char *option(const char *prefix, const char *value) {
    size_t a = strlen(prefix), b = strlen(value);
    if (a + b > 4U * 1024U * 1024U) return NULL;
    char *result = malloc(a + b + 1);
    if (result != NULL) { memcpy(result, prefix, a); memcpy(result + a, value, b + 1); }
    return result;
}
int main(int argc, char **argv) {
    if (argc != 4) return 2;
    char *classpath = option("-Djava.class.path=", argv[1]);
    char *library_path = option("-Djava.library.path=", argv[2]);
    char *temp_path = option("-Djava.io.tmpdir=", argv[3]);
    if (classpath == NULL || library_path == NULL || temp_path == NULL) return 2;
    JavaVMOption options[] = {{classpath, NULL}, {library_path, NULL}, {temp_path, NULL},
        {"-Xint", NULL}, {"-Xcheck:jni", NULL}, {"--enable-native-access=ALL-UNNAMED", NULL}};
    JavaVMInitArgs args = {0}; args.version = JNI_VERSION_1_8;
    args.nOptions = (jint)(sizeof(options) / sizeof(options[0])); args.options = options; args.ignoreUnrecognized = JNI_FALSE;
    JavaVM *vm = NULL; JNIEnv *env = NULL;
    jint started = JNI_CreateJavaVM(&vm, (void **)&env, &args);
    free(classpath); free(library_path); free(temp_path);
    if (started != JNI_OK || env == NULL) return 3;
    int failed = 0;
    jclass test = (*env)->FindClass(env, "mangashelf/host/ZstdCheck");
    jclass string = test == NULL ? NULL : (*env)->FindClass(env, "java/lang/String");
    jmethodID main_method = string == NULL ? NULL : (*env)->GetStaticMethodID(env, test, "main", "([Ljava/lang/String;)V");
    jobjectArray main_args = main_method == NULL ? NULL : (*env)->NewObjectArray(env, 1, string, NULL);
    jstring mode = main_args == NULL ? NULL : (*env)->NewStringUTF(env, "builtin");
    if (mode != NULL) {
        (*env)->SetObjectArrayElement(env, main_args, 0, mode);
        if (!(*env)->ExceptionCheck(env)) (*env)->CallStaticVoidMethod(env, test, main_method, main_args);
    } else failed = 1;
    if ((*env)->ExceptionCheck(env)) { (*env)->ExceptionDescribe(env); (*env)->ExceptionClear(env); failed = 1; }
    if (mode != NULL) (*env)->DeleteLocalRef(env, mode);
    if (main_args != NULL) (*env)->DeleteLocalRef(env, main_args);
    if (string != NULL) (*env)->DeleteLocalRef(env, string);
    if (test != NULL) (*env)->DeleteLocalRef(env, test);
    if (msl_zstd_shutdown(env) != JNI_OK) failed = 1;
    if ((*vm)->DestroyJavaVM(vm) != JNI_OK) failed = 1;
    if (!failed) fprintf(stderr, "PASS embedded VM shutdown after codec cleanup\n");
    return failed ? 4 : 0;
}
