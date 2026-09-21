#include "MSJavaRuntime.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <pthread.h>

static const char *plugin, *directory;
static int worker_result;

static void *worker(void *unused) {
    (void)unused;
    char output[1024];
    size_t needed = 0;
    worker_result = ms_java_call_string2("mangashelf/probe/RuntimeProbe", "run", plugin, directory, output, sizeof(output), &needed);
    if (!worker_result) puts(output);
    return NULL;
}

struct thread_test_data {
    int result;
    char output[1024];
};

static void *concurrent_worker(void *arg) {
    struct thread_test_data *t = (struct thread_test_data *)arg;
    size_t needed = 0;
    t->result = ms_java_call_string2("mangashelf/probe/RuntimeProbe", "run", plugin, directory, t->output, sizeof(t->output), &needed);
    return NULL;
}

static char *copy_str(const char *src) {
    size_t len = strlen(src);
    char *dst = (char *)malloc(len + 1);
    if (dst) { memcpy(dst, src, len + 1); }
    return dst;
}

static int dummy_net_called = 0;
static int dummy_net_received_body = 0;

static int dummy_net_handler(const void *req_json, size_t req_json_len,
                             const void *req_body, size_t req_body_len,
                             void **resp_meta, size_t *resp_meta_len,
                             void **resp_body, size_t *resp_body_len) {
    dummy_net_called++;
    if (!req_json || req_json_len == 0) return -1;
    if (req_body && req_body_len > 0) {
        if (req_body_len == strlen("MOCK_OKIO_BODY") &&
            memcmp(req_body, "MOCK_OKIO_BODY", req_body_len) == 0) {
            dummy_net_received_body = 1;
        }
    }
    const char *mock_meta = "{\"code\":200,\"message\":\"OK\"}";
    *resp_meta = copy_str(mock_meta);
    *resp_meta_len = strlen(mock_meta);
    const char *mock_body = "MOCK_RESPONSE_BYTES";
    *resp_body = copy_str(mock_body);
    *resp_body_len = strlen(mock_body);
    return 0;
}

static void dummy_free(void *ptr) {
    free(ptr);
}

static int dummy_channel_called = 0;
static int dummy_channel_valid = 0;

static void dummy_channel_handler(const char *topic, size_t topic_len,
                                  const char *content, size_t content_len) {
    dummy_channel_called = 1;
    if (topic && topic_len == strlen("test/topic") &&
        memcmp(topic, "test/topic", topic_len) == 0 &&
        content && content_len == strlen("{\"event\":\"ping\"}") &&
        memcmp(content, "{\"event\":\"ping\"}", content_len) == 0) {
        dummy_channel_valid = 1;
    }
}

static int test_native_net_and_channel(void) {
    ms_java_register_native_net(dummy_net_handler, dummy_free);
    ms_java_register_native_channel(dummy_channel_handler);

    /* Get env for current thread */
    /* Verify registration via direct JNI entrypoint */
    JNIEnv *env = NULL;
    char out_buf[64];
    size_t needed = 0;
    /* Touch probe to ensure thread is attached */
    int touch = ms_java_call_string2("mangashelf/probe/RuntimeProbe", "run", plugin, directory, out_buf, sizeof(out_buf), &needed);
    if (touch != MS_JAVA_OK) return 20;

    /* Get JavaVM via JNI */
    jsize vm_count = 0;
    JavaVM *vm = NULL;
    if (JNI_GetCreatedJavaVMs(&vm, 1, &vm_count) != JNI_OK || vm_count < 1) return 21;
    int need_detach = 0;
    jint env_state = (*vm)->GetEnv(vm, (void **)&env, JNI_VERSION_1_8);
    if (env_state == JNI_EDETACHED) {
        if ((*vm)->AttachCurrentThread(vm, (void **)&env, NULL) != JNI_OK) return 22;
        need_detach = 1;
    } else if (env_state != JNI_OK) {
        return 22;
    }

    const char *test_json = "{\"url\":\"https://example.com/test\",\"method\":\"GET\"}";
    jsize json_len = (jsize)strlen(test_json);
    jbyteArray json_arr = (*env)->NewByteArray(env, json_len);
    (*env)->SetByteArrayRegion(env, json_arr, 0, json_len, (const jbyte *)test_json);

    jobjectArray net_res = Java_org_tachiyomi_NativeNet_call_1utf8(env, NULL, json_arr, NULL);
    if (!net_res || (*env)->GetArrayLength(env, net_res) != 2) {
        if (need_detach) (*vm)->DetachCurrentThread(vm);
        return 23;
    }
    if (!dummy_net_called) {
        if (need_detach) (*vm)->DetachCurrentThread(vm);
        return 24;
    }

    jbyteArray meta_out = (jbyteArray)(*env)->GetObjectArrayElement(env, net_res, 0);
    jbyteArray body_out = (jbyteArray)(*env)->GetObjectArrayElement(env, net_res, 1);
    if (!meta_out || !body_out) {
        if (need_detach) (*vm)->DetachCurrentThread(vm);
        return 25;
    }
    if ((*env)->GetArrayLength(env, meta_out) <= 0 || (*env)->GetArrayLength(env, body_out) <= 0) {
        if (need_detach) (*vm)->DetachCurrentThread(vm);
        return 26;
    }

    /* Test Okio Buffer extraction via MockOkioBuffer */
    jclass probe_cls = (*env)->FindClass(env, "mangashelf/probe/RuntimeProbe");
    if (!probe_cls) {
        if (need_detach) (*vm)->DetachCurrentThread(vm);
        return 30;
    }
    jmethodID create_buf_mid = (*env)->GetStaticMethodID(env, probe_cls, "createMockBuffer", "(Ljava/lang/String;)Ljava/lang/Object;");
    if (!create_buf_mid) {
        if (need_detach) (*vm)->DetachCurrentThread(vm);
        return 31;
    }
    jstring body_str = (*env)->NewStringUTF(env, "MOCK_OKIO_BODY");
    if (!body_str) {
        if (need_detach) (*vm)->DetachCurrentThread(vm);
        return 32;
    }
    jobject mock_buf = (*env)->CallStaticObjectMethod(env, probe_cls, create_buf_mid, body_str);
    if (!mock_buf) {
        if (need_detach) (*vm)->DetachCurrentThread(vm);
        return 33;
    }

    dummy_net_received_body = 0;
    jobjectArray net_res2 = Java_org_tachiyomi_NativeNet_call_1utf8(env, NULL, json_arr, mock_buf);
    if (!net_res2 || (*env)->GetArrayLength(env, net_res2) != 2) {
        if (need_detach) (*vm)->DetachCurrentThread(vm);
        return 34;
    }
    if (!dummy_net_received_body) {
        if (need_detach) (*vm)->DetachCurrentThread(vm);
        return 35;
    }

    /* Test NativeChannel */
    const char *test_topic = "test/topic";
    const char *test_content = "{\"event\":\"ping\"}";
    jsize t_len = (jsize)strlen(test_topic);
    jsize c_len = (jsize)strlen(test_content);
    jbyteArray t_arr = (*env)->NewByteArray(env, t_len);
    jbyteArray c_arr = (*env)->NewByteArray(env, c_len);
    (*env)->SetByteArrayRegion(env, t_arr, 0, t_len, (const jbyte *)test_topic);
    (*env)->SetByteArrayRegion(env, c_arr, 0, c_len, (const jbyte *)test_content);

    Java_org_tachiyomi_NativeChannel_call_1utf8(env, NULL, t_arr, c_arr);
    if (!dummy_channel_called || !dummy_channel_valid) {
        if (need_detach) (*vm)->DetachCurrentThread(vm);
        return 27;
    }

    if (need_detach) (*vm)->DetachCurrentThread(vm);
    return 0;
}

int main(int argc, char **argv) {
    if (argc != 5) return 2;
    char early[16];
    size_t early_needed = 99;
    if (ms_java_call_string2("missing/Class", "run", "", "", early, sizeof(early), &early_needed) != MS_JAVA_NOT_STARTED) return 12;
    if (early_needed != 0 || early[0] != 0) return 13;
    if (ms_java_start(NULL, argv[1], argv[2]) != MS_JAVA_ARGUMENT) return 14;
    int status = ms_java_start(JNI_CreateJavaVM, argv[1], argv[2]);
    if (status) { fprintf(stderr, "JVM start failed: %d\n", status); return status; }
    if (ms_java_start(JNI_CreateJavaVM, argv[1], argv[2]) != MS_JAVA_ALREADY_STARTED) return 15;
    plugin = argv[3];
    directory = argv[4];

    /* Test 1 initial worker thread */
    pthread_t thread;
    if (pthread_create(&thread, NULL, worker, NULL)) return 9;
    if (pthread_join(thread, NULL)) return 10;
    if (worker_result) return worker_result;

    /* Test concurrent multithreading: 4 threads running in parallel */
    pthread_t threads[4];
    struct thread_test_data tdata[4];
    for (int i = 0; i < 4; i++) {
        tdata[i].result = -1;
        tdata[i].output[0] = 0;
        if (pthread_create(&threads[i], NULL, concurrent_worker, &tdata[i])) return 9;
    }
    for (int i = 0; i < 4; i++) {
        if (pthread_join(threads[i], NULL)) return 10;
        if (tdata[i].result != MS_JAVA_OK) return 100 + i;
    }

    char output[16];
    size_t needed = 0;
    /* Size discovery must be safe with no buffer, and report a useful bound. */
    int small = ms_java_call_string2("mangashelf/probe/RuntimeProbe", "run", plugin, directory, NULL, 0, &needed);
    if (small != MS_JAVA_BUFFER || needed <= sizeof(output)) return 16;
    if (ms_java_call_string2("missing/Class", "run", "", "", NULL, 1, &needed) != MS_JAVA_ARGUMENT) return 17;

    /* Test small buffer capacity with non-null pointer */
    char tiny_buf[8];
    size_t tiny_needed = 0;
    int tiny_rc = ms_java_call_string2("mangashelf/probe/RuntimeProbe", "run", plugin, directory, tiny_buf, sizeof(tiny_buf), &tiny_needed);
    if (tiny_rc != MS_JAVA_BUFFER || tiny_needed <= sizeof(tiny_buf)) return 18;

    /* A failed class lookup must not poison subsequent JNI calls on the same process. */
    int missing = ms_java_call_string2("missing/Class", "run", "", "", output, sizeof(output), &needed);
    if (missing != MS_JAVA_EXCEPTION) return 11;

    /* Test missing method on valid class returning MS_JAVA_EXCEPTION and subsequent recovery */
    char missing_buf[16];
    size_t missing_needed = 0;
    int missing_method = ms_java_call_string2("mangashelf/probe/RuntimeProbe", "missingMethod", "", "", missing_buf, sizeof(missing_buf), &missing_needed);
    if (missing_method != MS_JAVA_EXCEPTION) return 19;

    worker(NULL);
    if (worker_result) return worker_result;

    int net_status = test_native_net_and_channel();
    if (net_status) { fprintf(stderr, "NativeNet/Channel test failed: %d\n", net_status); return net_status; }

    return 0;
}
