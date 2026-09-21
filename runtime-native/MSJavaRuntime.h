#ifndef MS_JAVA_RUNTIME_H
#define MS_JAVA_RUNTIME_H
#include <stddef.h>
#include <jni.h>
#ifdef __cplusplus
extern "C" {
#endif
/* Process-lifetime JVM. Call off the UI thread. Function pointer selects the linked VM. */
typedef jint (JNICALL *ms_create_vm_fn)(JavaVM **, void **, void *);
int ms_java_start(ms_create_vm_fn create_vm, const char *classpath, const char *java_home);
/* Calls a static (String,String)->String method. Uses UTF-8, never Modified UTF-8 for arguments. */
int ms_java_call_string2(const char *class_name, const char *method_name,
                         const char *first, const char *second,
                         char *output, size_t capacity, size_t *needed);

/* NativeNet transport bridge. Invoked from Java worker threads. */
typedef int (*ms_native_net_fn)(const void *req_json, size_t req_json_len,
                                const void *req_body, size_t req_body_len,
                                void **resp_meta, size_t *resp_meta_len,
                                void **resp_body, size_t *resp_body_len);
typedef void (*ms_buffer_free_fn)(void *buffer);
void ms_java_register_native_net(ms_native_net_fn handler, ms_buffer_free_fn free_fn);

/* NativeChannel bridge for async event dispatch. */
typedef void (*ms_native_channel_fn)(const char *topic, size_t topic_len,
                                     const char *content, size_t content_len);
void ms_java_register_native_channel(ms_native_channel_fn handler);

/* JNI exports implemented in C for the Java backend */
JNIEXPORT jobjectArray JNICALL Java_org_tachiyomi_NativeNet_call_1utf8(JNIEnv *env, jclass cls, jbyteArray jsonUtf8, jobject buffer);
JNIEXPORT void JNICALL Java_org_tachiyomi_NativeChannel_call_1utf8(JNIEnv *env, jclass cls, jbyteArray topicUtf8, jbyteArray contentUtf8);

enum { MS_JAVA_OK=0, MS_JAVA_ARGUMENT=1, MS_JAVA_MEMORY=2,
       MS_JAVA_START_FAILED=3, MS_JAVA_NOT_STARTED=4, MS_JAVA_EXCEPTION=5,
       MS_JAVA_BUFFER=6, MS_JAVA_THREAD=7, MS_JAVA_ALREADY_STARTED=8 };
#ifdef __cplusplus
}
#endif
#endif
