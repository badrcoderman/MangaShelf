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
    JavaVMOption options[] = {{(char *)"-Xint", NULL}, {(char *)"-Xms32M", NULL}, {(char *)"-Xmx256M", NULL}, {cp, NULL}, {home, NULL}};
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

static ms_native_net_fn registered_net_fn = NULL;
static ms_buffer_free_fn registered_free_fn = NULL;
static pthread_mutex_t net_lock = PTHREAD_MUTEX_INITIALIZER;

static ms_native_channel_fn registered_channel_fn = NULL;
static pthread_mutex_t channel_lock = PTHREAD_MUTEX_INITIALIZER;

void ms_java_register_native_net(ms_native_net_fn handler, ms_buffer_free_fn free_fn) {
    pthread_mutex_lock(&net_lock);
    registered_net_fn = handler;
    registered_free_fn = free_fn;
    pthread_mutex_unlock(&net_lock);
}

void ms_java_register_native_channel(ms_native_channel_fn handler) {
    pthread_mutex_lock(&channel_lock);
    registered_channel_fn = handler;
    pthread_mutex_unlock(&channel_lock);
}

/* All lengths reaching this helper have been bounded below JNI's signed jsize. */
static jobjectArray net_response(JNIEnv *env, const void *meta, size_t meta_len,
                                const void *body, size_t body_len) {
    if (!meta || !meta_len || meta_len > MS_JAVA_NET_MAX_METADATA ||
        body_len > MS_JAVA_NET_MAX_RESPONSE_BODY || (!body && body_len)) return NULL;
    jclass byte_array_class = (*env)->FindClass(env, "[B");
    if (!byte_array_class) return NULL;
    jobjectArray result = (*env)->NewObjectArray(env, 2, byte_array_class, NULL);
    if (!result) return NULL;
    jbyteArray meta_out = (*env)->NewByteArray(env, (jsize)meta_len);
    if (!meta_out) return NULL;
    (*env)->SetByteArrayRegion(env, meta_out, 0, (jsize)meta_len, (const jbyte *)meta);
    if ((*env)->ExceptionCheck(env)) return NULL;
    (*env)->SetObjectArrayElement(env, result, 0, meta_out);
    if ((*env)->ExceptionCheck(env)) return NULL;
    jbyteArray body_out = (*env)->NewByteArray(env, (jsize)body_len);
    if (!body_out) return NULL;
    if (body_len) {
        (*env)->SetByteArrayRegion(env, body_out, 0, (jsize)body_len, (const jbyte *)body);
        if ((*env)->ExceptionCheck(env)) return NULL;
    }
    (*env)->SetObjectArrayElement(env, result, 1, body_out);
    return (*env)->ExceptionCheck(env) ? NULL : result;
}

JNIEXPORT jobjectArray JNICALL Java_org_tachiyomi_NativeNet_call_1utf8(JNIEnv *env, jclass cls, jbyteArray jsonUtf8, jobject buffer) {
    (void)cls;
    if (!env || (*env)->ExceptionCheck(env)) return NULL;
    if ((*env)->PushLocalFrame(env, 16) != JNI_OK) return NULL;
    const char *error = NULL;
    jobjectArray result = NULL;
    jsize json_len = 0;
    jbyte *json_bytes = NULL;
    size_t req_body_len = 0;
    jbyteArray body_array = NULL;
    jbyte *body_bytes = NULL;
    void *resp_meta = NULL, *resp_body = NULL;
    size_t resp_meta_len = 0, resp_body_len = 0;
    ms_buffer_free_fn free_fn = NULL;

    if (!jsonUtf8) {
        error = "{\"code\":400,\"error\":\"Invalid NativeNet request metadata\"}";
        goto respond;
    }
    json_len = (*env)->GetArrayLength(env, jsonUtf8);
    if ((*env)->ExceptionCheck(env)) goto cleanup;
    if (json_len <= 0 || json_len > MS_JAVA_NET_MAX_METADATA) {
        error = "{\"code\":400,\"error\":\"Invalid NativeNet request metadata\"}";
        goto respond;
    }

    if (buffer) {
        jclass byte_arr_cls = (*env)->FindClass(env, "[B");
        jlong expected_body_len = -1;
        if (!byte_arr_cls) goto cleanup;
        if ((*env)->IsInstanceOf(env, buffer, byte_arr_cls)) {
            body_array = (jbyteArray)buffer;
        } else {
            jclass buf_cls = (*env)->GetObjectClass(env, buffer);
            if (!buf_cls) goto cleanup;
            /* Check Okio's size before its allocating, consuming readByteArray. */
            jmethodID size_mid = (*env)->GetMethodID(env, buf_cls, "size", "()J");
            if (!size_mid) goto invalid_body;
            expected_body_len = (*env)->CallLongMethod(env, buffer, size_mid);
            if ((*env)->ExceptionCheck(env)) goto invalid_body;
            if (expected_body_len < 0 || expected_body_len > MS_JAVA_NET_MAX_REQUEST_BODY) goto invalid_body;
            jmethodID read_bytes_mid = (*env)->GetMethodID(env, buf_cls, "readByteArray", "()[B");
            if (!read_bytes_mid) goto invalid_body;
            body_array = (jbyteArray)(*env)->CallObjectMethod(env, buffer, read_bytes_mid);
            if ((*env)->ExceptionCheck(env) || !body_array) goto invalid_body;
        }
        jsize b_len = (*env)->GetArrayLength(env, body_array);
        if ((*env)->ExceptionCheck(env)) goto cleanup;
        if (b_len < 0 || b_len > MS_JAVA_NET_MAX_REQUEST_BODY ||
            (expected_body_len >= 0 && expected_body_len != b_len)) goto invalid_body;
        req_body_len = (size_t)b_len;
        if (b_len > 0) {
            body_bytes = (*env)->GetByteArrayElements(env, body_array, NULL);
            if (!body_bytes) goto cleanup;
        }
    }
    json_bytes = (*env)->GetByteArrayElements(env, jsonUtf8, NULL);
    if (!json_bytes) goto cleanup;

    pthread_mutex_lock(&net_lock);
    ms_native_net_fn net_fn = registered_net_fn;
    free_fn = registered_free_fn;
    pthread_mutex_unlock(&net_lock);

    if (!net_fn || !free_fn) {
        error = "{\"code\":500,\"error\":\"NativeNet transport unavailable\"}";
        goto respond;
    }
    int status = net_fn((const void *)json_bytes, (size_t)json_len,
                        body_bytes, req_body_len,
                        &resp_meta, &resp_meta_len, &resp_body, &resp_body_len);
    if (status != 0) {
        error = "{\"code\":500,\"error\":\"NativeNet transport failed\"}";
    } else if (!resp_meta || !resp_meta_len || resp_meta_len > MS_JAVA_NET_MAX_METADATA ||
               resp_body_len > MS_JAVA_NET_MAX_RESPONSE_BODY ||
               (!resp_body && resp_body_len) || (resp_body && resp_body == resp_meta)) {
        error = "{\"code\":500,\"error\":\"Invalid NativeNet transport response\"}";
    }
    goto respond;
invalid_body:
    /* A rejected body is a failed request, never an empty successful upload. */
    if ((*env)->ExceptionCheck(env)) (*env)->ExceptionClear(env);
    error = "{\"code\":400,\"error\":\"Invalid NativeNet request body\"}";
respond:
    if (json_bytes) {
        (*env)->ReleaseByteArrayElements(env, jsonUtf8, json_bytes, JNI_ABORT);
        json_bytes = NULL;
    }
    if (body_bytes) {
        (*env)->ReleaseByteArrayElements(env, body_array, body_bytes, JNI_ABORT);
        body_bytes = NULL;
    }
    if (error) result = net_response(env, error, strlen(error), NULL, 0);
    else result = net_response(env, resp_meta, resp_meta_len, resp_body, resp_body_len);
cleanup:
    if (json_bytes) (*env)->ReleaseByteArrayElements(env, jsonUtf8, json_bytes, JNI_ABORT);
    if (body_bytes) (*env)->ReleaseByteArrayElements(env, body_array, body_bytes, JNI_ABORT);
    if (free_fn) {
        if (resp_meta) free_fn(resp_meta);
        if (resp_body && resp_body != resp_meta) free_fn(resp_body);
    }
    return (jobjectArray)(*env)->PopLocalFrame(env, result);
}

JNIEXPORT void JNICALL Java_org_tachiyomi_NativeChannel_call_1utf8(JNIEnv *env, jclass cls, jbyteArray topicUtf8, jbyteArray contentUtf8) {
    (void)cls;
    if (!env || !topicUtf8 || !contentUtf8) return;
    jsize topic_len = (*env)->GetArrayLength(env, topicUtf8);
    jsize content_len = (*env)->GetArrayLength(env, contentUtf8);
    if (topic_len <= 0 || topic_len > 64 * 1024 || content_len < 0 || content_len > 4 * 1024 * 1024) return;

    jbyte *topic_bytes = (*env)->GetByteArrayElements(env, topicUtf8, NULL);
    jbyte *content_bytes = (*env)->GetByteArrayElements(env, contentUtf8, NULL);
    if (!topic_bytes || !content_bytes) {
        if (topic_bytes) (*env)->ReleaseByteArrayElements(env, topicUtf8, topic_bytes, JNI_ABORT);
        if (content_bytes) (*env)->ReleaseByteArrayElements(env, contentUtf8, content_bytes, JNI_ABORT);
        return;
    }

    pthread_mutex_lock(&channel_lock);
    ms_native_channel_fn channel_fn = registered_channel_fn;
    pthread_mutex_unlock(&channel_lock);

    if (channel_fn) {
        channel_fn((const char *)topic_bytes, (size_t)topic_len,
                   (const char *)content_bytes, (size_t)content_len);
    }

    (*env)->ReleaseByteArrayElements(env, topicUtf8, topic_bytes, JNI_ABORT);
    (*env)->ReleaseByteArrayElements(env, contentUtf8, content_bytes, JNI_ABORT);
}

