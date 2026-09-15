#include "MSJavaRuntime.h"
#include <pthread.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <stdint.h>

static pthread_mutex_t runtime_lock = PTHREAD_MUTEX_INITIALIZER;
static JavaVM *runtime_vm;
static int start_attempted;

static char *option(const char *prefix, const char *value) {
    size_t a = strlen(prefix), b = strlen(value);
    if (b > 1024 * 1024 || a > SIZE_MAX - b - 1) return NULL;
    char *result = malloc(a + b + 1);
    if (result) { memcpy(result, prefix, a); memcpy(result+a, value, b+1); }
    return result;
}

int ms_java_start(ms_create_vm_fn create_vm, const char *classpath, const char *java_home) {
    if (!create_vm || !classpath || !*classpath || !java_home || !*java_home) return MS_JAVA_ARGUMENT;
    char *cp = option("-Djava.class.path=", classpath), *home = option("-Djava.home=", java_home);
    if (!cp || !home) { free(cp); free(home); return MS_JAVA_MEMORY; }
    pthread_mutex_lock(&runtime_lock);
    if (start_attempted) {
        pthread_mutex_unlock(&runtime_lock); free(cp); free(home); return MS_JAVA_ALREADY_STARTED;
    }
    /* JVM restart in one process is not assumed safe, including after a failed launch. */
    start_attempted = 1;
    JavaVMOption options[] = {{"-Xint", NULL}, {"-Xms32M", NULL}, {"-Xmx256M", NULL}, {cp, NULL}, {home, NULL}};
    JavaVMInitArgs args = {0};
    args.version = JNI_VERSION_1_8;
    args.nOptions = (jint)(sizeof(options)/sizeof(options[0]));
    args.options = options;
    args.ignoreUnrecognized = JNI_FALSE;
    JNIEnv *env = NULL;
    JavaVM *created = NULL;
    jint status = create_vm(&created, (void **)&env, &args);
    if (status == JNI_OK && created && env) runtime_vm = created;
    int result = runtime_vm ? MS_JAVA_OK : MS_JAVA_START_FAILED;
    /* The creating thread owns its initial JNI attachment; do not retain its JNIEnv. */
    if (runtime_vm && (*runtime_vm)->DetachCurrentThread(runtime_vm) != JNI_OK) result = MS_JAVA_THREAD;
    pthread_mutex_unlock(&runtime_lock);
    free(cp); free(home);
    return result;
}

static jstring from_utf8(JNIEnv *env, const char *text) {
    size_t size = strlen(text);
    if (size > 1024*1024) return NULL;
    jclass string = (*env)->FindClass(env, "java/lang/String");
    if (!string) return NULL;
    jmethodID constructor = (*env)->GetMethodID(env, string, "<init>", "([BLjava/lang/String;)V");
    if (!constructor) return NULL;
    jbyteArray bytes = (*env)->NewByteArray(env, (jsize)size);
    if (!bytes) return NULL;
    (*env)->SetByteArrayRegion(env, bytes, 0, (jsize)size, (const jbyte *)text);
    if ((*env)->ExceptionCheck(env)) return NULL;
    jstring charset = (*env)->NewStringUTF(env, "UTF-8");
    if (!charset) return NULL;
    return (jstring)(*env)->NewObject(env, string, constructor, bytes, charset);
}

int ms_java_call_string2(const char *class_name, const char *method_name,
                         const char *first, const char *second,
                         char *output, size_t capacity, size_t *needed) {
    if (!class_name || !method_name || !first || !second || !needed || (!output && capacity)) return MS_JAVA_ARGUMENT;
    *needed = 0;
    if (capacity) output[0] = 0;
    pthread_mutex_lock(&runtime_lock);
    JavaVM *vm = runtime_vm;
    pthread_mutex_unlock(&runtime_lock);
    if (!vm) return MS_JAVA_NOT_STARTED;
    JNIEnv *env = NULL;
    jint state = (*vm)->GetEnv(vm, (void **)&env, JNI_VERSION_1_8);
    int attached = 0;
    if (state == JNI_EDETACHED) {
        if ((*vm)->AttachCurrentThread(vm, (void **)&env, NULL) != JNI_OK) return MS_JAVA_THREAD;
        attached = 1;
    } else if (state != JNI_OK) return MS_JAVA_THREAD;
    int result = MS_JAVA_EXCEPTION;
    if ((*env)->PushLocalFrame(env, 32) != JNI_OK) goto finish;
    jclass type = (*env)->FindClass(env, class_name);
    if (!type) goto pop;
    jmethodID method = (*env)->GetStaticMethodID(env, type, method_name, "(Ljava/lang/String;Ljava/lang/String;)Ljava/lang/String;");
    if (!method) goto pop;
    jstring a = from_utf8(env, first);
    if (!a || (*env)->ExceptionCheck(env)) goto pop;
    jstring b = from_utf8(env, second);
    if (!b || (*env)->ExceptionCheck(env)) goto pop;
    jstring answer = (jstring)(*env)->CallStaticObjectMethod(env, type, method, a, b);
    if (!answer || (*env)->ExceptionCheck(env)) goto pop;
    jclass string = (*env)->FindClass(env, "java/lang/String");
    if (!string) goto pop;
    jmethodID get_bytes = (*env)->GetMethodID(env, string, "getBytes", "(Ljava/lang/String;)[B");
    if (!get_bytes) goto pop;
    jstring utf8 = (*env)->NewStringUTF(env, "UTF-8");
    if (!utf8) goto pop;
    jbyteArray bytes = (jbyteArray)(*env)->CallObjectMethod(env, answer, get_bytes, utf8);
    if (!bytes || (*env)->ExceptionCheck(env)) goto pop;
    jsize length = (*env)->GetArrayLength(env, bytes);
    *needed = (size_t)length + 1;
    if (*needed > capacity) { result = MS_JAVA_BUFFER; goto pop; }
    (*env)->GetByteArrayRegion(env, bytes, 0, length, (jbyte *)output);
    if ((*env)->ExceptionCheck(env)) goto pop;
    output[length] = 0;
    result = MS_JAVA_OK;
pop:
    (*env)->PopLocalFrame(env, NULL);
finish:
    if ((*env)->ExceptionCheck(env)) (*env)->ExceptionClear(env);
    if (attached && (*vm)->DetachCurrentThread(vm) != JNI_OK) result = MS_JAVA_THREAD;
    return result;
}
