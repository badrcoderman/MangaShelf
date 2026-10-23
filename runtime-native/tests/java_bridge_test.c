#include "MSJavaBridge.h"
#include <assert.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

static const char *fixture = "mangashelf/bridgefixture/BridgeFixture";
static JavaVM *vm;

static jint JNICALL create_vm(JavaVM **created, void **env, void *args) {
    jint result = JNI_CreateJavaVM(created, env, args);
    vm = *created;
    return result;
}

static void assert_detached(void) {
    JNIEnv *env = NULL;
    assert((*vm)->GetEnv(vm, (void **)&env, JNI_VERSION_1_8) == JNI_EDETACHED);
}

static char *raw_call(const char *action, const char *payload, size_t *length) {
    char *output = NULL;
    assert(ms_java_call_string2_owned(fixture, "dispatch", action, payload,
                                     MS_JAVA_MAX_STRING_BYTES, &output, length) == MS_JAVA_OK);
    assert(output != NULL && output[*length] == 0);
    return output;
}

static int calls(void) {
    size_t length = 0;
    char *value = raw_call("calls", "", &length);
    int result = atoi(value);
    ms_java_free_string(value);
    return result;
}

static void test_lookup_and_exception_recovery(void) {
    assert(ms_java_bridge_install("missing/Fixture", "dispatch") == MS_BRIDGE_CLASS_NOT_FOUND);
    assert(ms_bridge_is_vm_available() == 0);
    assert(ms_java_bridge_install(fixture, "missing") == MS_BRIDGE_METHOD_NOT_FOUND);
    assert(ms_bridge_is_vm_available() == 0);
    assert(ms_java_bridge_install("mangashelf/bridgefixture/BridgeFixture$BrokenInitializer", "dispatch") == MS_BRIDGE_JAVA_EXCEPTION);
    assert(ms_bridge_is_vm_available() == 0);
    /* The JVM remembers a failed initializer and subsequently reports
     * NoClassDefFoundError, even though this class exists on the classpath. */
    assert(ms_java_bridge_install("mangashelf/bridgefixture/BridgeFixture$BrokenInitializer", "dispatch") == MS_BRIDGE_CLASS_NOT_FOUND);
    assert(ms_bridge_is_vm_available() == 0);
    size_t recovered_length = 0;
    char *recovered = raw_call("echo", "healthy after initialization failure", &recovered_length);
    assert(strcmp(recovered, "healthy after initialization failure") == 0);
    ms_java_free_string(recovered);
    assert(ms_java_bridge_install(fixture, "dispatch") == MS_BRIDGE_OK);
    assert(ms_bridge_is_vm_available() == 1);
    char *owned = (char *)1;
    size_t length = 99;
    int before = calls();
    assert(ms_java_bridge_dispatch_owned("throw", "", &owned, &length) == MS_BRIDGE_JAVA_EXCEPTION);
    assert(owned == NULL && length == 0 && calls() == before + 1);
    assert(ms_java_bridge_dispatch_owned("null", "", &owned, &length) == MS_BRIDGE_JAVA_EXCEPTION);
    assert(owned == NULL && length == 0);
    assert(ms_java_bridge_dispatch_owned("echo", "العربية📚", &owned, &length) == MS_BRIDGE_OK);
    assert(length == strlen("العربية📚") && strcmp(owned, "العربية📚") == 0);
    ms_java_free_string(owned);
    assert_detached();
}

static void test_fixed_dispatch_and_once_only(void) {
    int before = calls();
    char fixed[128] = "stale";
    size_t needed = 99;
    assert(ms_bridge_dispatch("echo", "value", fixed, sizeof(fixed), &needed) == MS_BRIDGE_OK);
    assert(strcmp(fixed, "value") == 0 && needed == 5 && calls() == before + 1);
    before = calls();
    assert(ms_bridge_dispatch("large", "", fixed, sizeof(fixed), &needed) == MS_BRIDGE_BUFFER_TOO_SMALL);
    assert(fixed[0] == 0 && needed == 100000 + strlen("العربية📚") && calls() == before + 1);
    before = calls();
    assert(ms_bridge_dispatch("echo", "sized", NULL, 0, &needed) == MS_BRIDGE_BUFFER_TOO_SMALL);
    assert(needed == 5 && calls() == before + 1);
    before = calls();
    assert(ms_bridge_dispatch("echo", "", fixed, 1, &needed) == MS_BRIDGE_OK);
    assert(fixed[0] == 0 && needed == 0 && calls() == before + 1);
    assert(ms_bridge_dispatch("echo", "value", NULL, 0, NULL) == MS_BRIDGE_BUFFER_TOO_SMALL);
}

static void test_owned_bounds_and_nul(void) {
    char *owned = NULL;
    size_t length = 0;
    int before = calls();
    assert(ms_java_bridge_dispatch_owned("large", "", &owned, &length) == MS_BRIDGE_OK);
    assert(length == 100000 + strlen("العربية📚") && owned[length] == 0 && calls() == before + 1);
    ms_java_free_string(owned);
    before = calls();
    assert(ms_java_call_string2_owned(fixture, "dispatch", "echo", "12345", 4,
                                     &owned, &length) == MS_JAVA_LIMIT);
    assert(owned == NULL && length == 0 && calls() == before + 1);
    before = calls();
    assert(ms_java_bridge_dispatch_owned("oversize", "", &owned, &length) == MS_BRIDGE_BUFFER_TOO_SMALL);
    assert(owned == NULL && length == 0 && calls() == before + 1);
    assert(ms_java_call_string2_owned(fixture, "dispatch", "nul", "", 8,
                                     &owned, &length) == MS_JAVA_OK);
    assert(length == 3 && owned[0] == 'a' && owned[1] == 0 && owned[2] == 'b');
    ms_java_free_string(owned);
    assert(ms_java_bridge_dispatch_owned("nul", "", &owned, &length) == MS_BRIDGE_JNI_ERROR);
    assert(owned == NULL && length == 0);
    before = calls();
    assert(ms_java_call_string2_owned(fixture, "dispatch", "echo", "",
                                     (size_t)MS_JAVA_MAX_STRING_BYTES + 1, &owned, &length) == MS_JAVA_ARGUMENT);
    assert(calls() == before && owned == NULL && length == 0);
    assert(ms_java_call_string2_owned(fixture, "dispatch", "echo", "", 0,
                                     &owned, &length) == MS_JAVA_OK);
    assert(owned != NULL && length == 0 && owned[0] == 0);
    ms_java_free_string(owned);
    char *too_long = malloc(1024 * 1024 + 2);
    assert(too_long != NULL);
    memset(too_long, 'x', 1024 * 1024 + 1);
    too_long[1024 * 1024 + 1] = 0;
    before = calls();
    assert(ms_java_bridge_dispatch_owned("echo", too_long, &owned, &length) == MS_BRIDGE_INVALID_ARG);
    assert(owned == NULL && length == 0 && calls() == before);
    free(too_long);
}

static void test_attachment_and_foreign_exception(void) {
    JNIEnv *env = NULL;
    assert((*vm)->AttachCurrentThread(vm, (void **)&env, NULL) == JNI_OK);
    size_t length = 0;
    char *owned = raw_call("echo", "attached", &length);
    ms_java_free_string(owned);
    JNIEnv *after = NULL;
    assert((*vm)->GetEnv(vm, (void **)&after, JNI_VERSION_1_8) == JNI_OK && after == env);
    jclass error = (*env)->FindClass(env, "java/lang/IllegalArgumentException");
    assert(error != NULL && (*env)->ThrowNew(env, error, "caller-owned pending exception") == JNI_OK);
    jthrowable pending = (*env)->ExceptionOccurred(env);
    assert(pending != NULL);
    owned = (char *)1;
    length = 99;
    assert(ms_java_call_string2_owned(fixture, "dispatch", "echo", "ignored", 128,
                                     &owned, &length) == MS_JAVA_EXCEPTION);
    assert(owned == NULL && length == 0 && (*env)->ExceptionCheck(env));
    jthrowable preserved = (*env)->ExceptionOccurred(env);
    assert((*env)->IsSameObject(env, pending, preserved));
    (*env)->ExceptionClear(env);
    (*env)->DeleteLocalRef(env, pending);
    (*env)->DeleteLocalRef(env, preserved);
    (*env)->DeleteLocalRef(env, error);
    assert((*vm)->DetachCurrentThread(vm) == JNI_OK);
    assert_detached();
}

static void *concurrent_worker(void *unused) {
    (void)unused;
    for (int i = 0; i < 20; i++) {
        char *owned = NULL;
        size_t length = 0;
        assert(ms_java_bridge_dispatch_owned("echo", "worker📚", &owned, &length) == MS_BRIDGE_OK);
        assert(length == strlen("worker📚") && strcmp(owned, "worker📚") == 0);
        ms_java_free_string(owned);
        assert_detached();
    }
    return NULL;
}

static void test_concurrent_workers(void) {
    pthread_t threads[4];
    int before = calls();
    for (int i = 0; i < 4; i++) assert(pthread_create(&threads[i], NULL, concurrent_worker, NULL) == 0);
    for (int i = 0; i < 4; i++) assert(pthread_join(threads[i], NULL) == 0);
    assert(calls() == before + 80);
}

static void *blocked_worker(void *unused) {
    (void)unused;
    char output[32];
    size_t needed = 0;
    assert(ms_bridge_dispatch("blocked", "", output, sizeof(output), &needed) == MS_BRIDGE_OK);
    assert(strcmp(output, "finished") == 0 && needed == 8);
    assert_detached();
    return NULL;
}

static void test_lifecycle_in_flight(void) {
    pthread_t thread;
    assert(pthread_create(&thread, NULL, blocked_worker, NULL) == 0);
    int entered = 0;
    for (int i = 0; i < 1000; i++) {
        size_t length = 0;
        char *value = raw_call("entered", "", &length);
        entered = strcmp(value, "true") == 0;
        ms_java_free_string(value);
        if (entered) break;
        struct timespec interval = {0, 1000000};
        nanosleep(&interval, NULL);
    }
    assert(entered);
    ms_java_bridge_set_active(0);
    assert(ms_bridge_is_vm_available() == 0 && ms_java_is_started() == 1);
    char *owned = (char *)1;
    size_t length = 99;
    assert(ms_java_bridge_dispatch_owned("echo", "", &owned, &length) == MS_BRIDGE_NOT_STARTED);
    assert(owned == NULL && length == 0);
    assert(ms_bridge_dispatch("echo", "", NULL, 0, NULL) == MS_BRIDGE_NOT_STARTED);
    owned = raw_call("release", "", &length);
    ms_java_free_string(owned);
    assert(pthread_join(thread, NULL) == 0);
    ms_java_bridge_set_active(1);
    assert(ms_bridge_is_vm_available() == 1);
    owned = NULL;
    assert(ms_java_bridge_dispatch_owned("echo", "resumed", &owned, &length) == MS_BRIDGE_OK);
    assert(strcmp(owned, "resumed") == 0);
    ms_java_free_string(owned);
    ms_java_bridge_uninstall();
    ms_java_bridge_set_active(1);
    assert(ms_bridge_is_vm_available() == 0 && ms_java_is_started() == 1);
    assert(ms_java_bridge_dispatch_owned("echo", "", &owned, &length) == MS_BRIDGE_NOT_STARTED);
}

int main(int argc, char **argv) {
    assert(argc == 3);
    char *owned = (char *)1;
    size_t length = 99;
    assert(ms_java_is_started() == 0);
    assert(ms_java_call_string2_owned(fixture, "dispatch", "echo", "", 128,
                                     &owned, &length) == MS_JAVA_NOT_STARTED);
    assert(owned == NULL && length == 0);
    assert(ms_java_bridge_install(fixture, "dispatch") == MS_BRIDGE_NOT_STARTED);
    assert(ms_bridge_is_vm_available() == 0);
    assert(ms_java_start(create_vm, argv[1], argv[2]) == MS_JAVA_OK);
    assert(ms_java_is_started() == 1);
    assert_detached();
    assert(ms_java_start(create_vm, argv[1], argv[2]) == MS_JAVA_ALREADY_STARTED);
    test_lookup_and_exception_recovery();
    test_fixed_dispatch_and_once_only();
    test_owned_bounds_and_nul();
    test_attachment_and_foreign_exception();
    test_concurrent_workers();
    test_lifecycle_in_flight();
    puts("PASS: JNI owned response, callback bridge dispatch, single execution, bounds, exceptions, attachment, concurrency, lifecycle");
    return 0;
}
