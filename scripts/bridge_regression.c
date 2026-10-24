#include "MSJNIBridge.h"

#include <assert.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int dispatch_calls;
static int net_calls;

static int empty_dispatch(const char *action, const char *payload, char *output,
                          size_t capacity, size_t *needed) {
    assert(action != NULL && payload != NULL);
    assert(output == NULL || capacity == 0 || output[0] == '\0');
    assert(needed == NULL || *needed == 0);
    ++dispatch_calls;
    /* Reentrant bridge access must not run under the registration mutex. */
    assert(ms_bridge_is_vm_available() == 1);
    return MS_BRIDGE_METHOD_NOT_FOUND;
}

static int response_dispatch(const char *action, const char *payload, char *output,
                             size_t capacity, size_t *needed) {
    static const char response[] = "{\"ok\":true}";
    (void)empty_dispatch(action, payload, output, capacity, needed);
    if (needed != NULL) *needed = sizeof(response) - 1;
    if (capacity < sizeof(response)) return MS_BRIDGE_BUFFER_TOO_SMALL;
    assert(output != NULL);
    memcpy(output, response, sizeof(response));
    return MS_BRIDGE_OK;
}

static void reset_bridge(void) {
    ms_bridge_register_dispatcher(NULL);
    ms_bridge_register_net(NULL, NULL);
    dispatch_calls = 0;
    net_calls = 0;
}

static void test_absent_dispatcher_cannot_be_enabled(void) {
    reset_bridge();
    assert(ms_bridge_is_vm_available() == 0);
    ms_bridge_set_vm_available(9);
    assert(ms_bridge_is_vm_available() == 0);
    char output[] = "stale";
    size_t needed = 123;
    assert(ms_bridge_dispatch("ping", "{}", output, sizeof(output), &needed)
           == MS_BRIDGE_NOT_STARTED);
    assert(output[0] == '\0' && needed == 0);
}

static void test_lifecycle_stops_subsequent_calls(void) {
    reset_bridge();
    ms_bridge_register_dispatcher(empty_dispatch);
    assert(ms_bridge_is_vm_available() == 1);
    assert(ms_bridge_dispatch("ping", "{}", NULL, 0, NULL)
           == MS_BRIDGE_METHOD_NOT_FOUND);
    assert(dispatch_calls == 1);
    ms_bridge_set_vm_available(0);
    assert(ms_bridge_is_vm_available() == 0);
    char output[] = "stale";
    size_t needed = 123;
    assert(ms_bridge_dispatch("ping", "{}", output, sizeof(output), &needed)
           == MS_BRIDGE_NOT_STARTED);
    assert(output[0] == '\0' && needed == 0 && dispatch_calls == 1);
    ms_bridge_set_vm_available(-1);
    assert(ms_bridge_is_vm_available() == 1);
    ms_bridge_register_dispatcher(NULL);
    assert(ms_bridge_is_vm_available() == 0);
    ms_bridge_set_vm_available(1);
    assert(ms_bridge_is_vm_available() == 0);
    assert(ms_bridge_dispatch("ping", "{}", NULL, 0, NULL) == MS_BRIDGE_NOT_STARTED);
    assert(dispatch_calls == 1);
}

static void test_dispatch_outputs_are_initialized(void) {
    reset_bridge();
    ms_bridge_register_dispatcher(empty_dispatch);
    char output[] = "stale";
    size_t needed = 123;
    assert(ms_bridge_dispatch("unknown", "{}", output, sizeof(output), &needed)
           == MS_BRIDGE_METHOD_NOT_FOUND);
    assert(output[0] == '\0' && needed == 0 && dispatch_calls == 1);
    assert(ms_bridge_dispatch("unknown", "{}", NULL, 0, NULL)
           == MS_BRIDGE_METHOD_NOT_FOUND);
    output[0] = 'x';
    needed = 123;
    assert(ms_bridge_dispatch("unknown", "{}", output, 0, &needed)
           == MS_BRIDGE_METHOD_NOT_FOUND);
    assert(output[0] == 'x' && needed == 0);
}

static void test_dispatch_rejects_invalid_inputs_without_callback(void) {
    reset_bridge();
    ms_bridge_register_dispatcher(empty_dispatch);
    char output[] = "stale";
    size_t needed = 123;
    assert(ms_bridge_dispatch(NULL, "{}", output, sizeof(output), &needed)
           == MS_BRIDGE_INVALID_ARG);
    assert(output[0] == '\0' && needed == 0);
    output[0] = 'x';
    needed = 123;
    assert(ms_bridge_dispatch("ping", NULL, output, sizeof(output), &needed)
           == MS_BRIDGE_INVALID_ARG);
    assert(output[0] == '\0' && needed == 0);
    needed = 123;
    assert(ms_bridge_dispatch("ping", "{}", NULL, 1, &needed)
           == MS_BRIDGE_INVALID_ARG);
    assert(needed == 0 && dispatch_calls == 0);
    assert(ms_bridge_dispatch(NULL, NULL, NULL, 0, NULL) == MS_BRIDGE_INVALID_ARG);
}

static void test_dispatch_preserves_callback_results(void) {
    reset_bridge();
    ms_bridge_register_dispatcher(response_dispatch);
    char output[32] = "stale";
    size_t needed = 123;
    assert(ms_bridge_dispatch("ping", "{}", output, sizeof(output), &needed)
           == MS_BRIDGE_OK);
    assert(strcmp(output, "{\"ok\":true}") == 0 && needed == strlen(output));
    memset(output, 'x', sizeof(output));
    assert(ms_bridge_dispatch("ping", "{}", output, 1, &needed)
           == MS_BRIDGE_BUFFER_TOO_SMALL);
    assert(output[0] == '\0' && output[1] == 'x' && needed == 11);
    assert(ms_bridge_dispatch("ping", "{}", NULL, 0, &needed)
           == MS_BRIDGE_BUFFER_TOO_SMALL);
    assert(needed == 11);
}

static void empty_net(const char *request, const uint8_t *body, size_t body_len,
                      char **response, uint8_t **response_body, size_t *response_len) {
    assert(request != NULL && (body != NULL || body_len == 0));
    assert(response == NULL || *response == NULL);
    assert(response_body == NULL || *response_body == NULL);
    assert(response_len == NULL || *response_len == 0);
    ++net_calls;
    ms_bridge_register_net(empty_net, NULL);
}

static char response_json[] = "{}";
static uint8_t response_bytes[] = {0, 1, 255};

static void response_net(const char *request, const uint8_t *body, size_t body_len,
                         char **response, uint8_t **response_body, size_t *response_len) {
    empty_net(request, body, body_len, response, response_body, response_len);
    if (response != NULL) *response = response_json;
    if (response_body != NULL) *response_body = response_bytes;
    if (response_len != NULL) *response_len = sizeof(response_bytes);
}

static void test_network_outputs_are_initialized(void) {
    reset_bridge();
    char *response = response_json;
    uint8_t *body = response_bytes;
    size_t length = 123;
    ms_bridge_invoke_net("{}", NULL, 0, &response, &body, &length);
    assert(response == NULL && body == NULL && length == 0);
    ms_bridge_register_net(empty_net, NULL);
    response = response_json;
    body = response_bytes;
    length = 123;
    ms_bridge_invoke_net("{}", NULL, 0, &response, &body, &length);
    assert(response == NULL && body == NULL && length == 0 && net_calls == 1);
    ms_bridge_invoke_net("{}", response_bytes, sizeof(response_bytes), NULL, NULL, NULL);
    assert(net_calls == 2);
}

static void test_network_rejects_invalid_inputs_without_callback(void) {
    reset_bridge();
    ms_bridge_register_net(empty_net, NULL);
    char *response = response_json;
    uint8_t *body = response_bytes;
    size_t length = 123;
    ms_bridge_invoke_net(NULL, NULL, 0, &response, &body, &length);
    assert(response == NULL && body == NULL && length == 0);
    response = response_json;
    body = response_bytes;
    length = 123;
    ms_bridge_invoke_net("{}", NULL, 1, &response, &body, &length);
    assert(response == NULL && body == NULL && length == 0 && net_calls == 0);
    ms_bridge_invoke_net(NULL, NULL, 1, NULL, NULL, NULL);
}

static void test_network_preserves_callback_outputs(void) {
    reset_bridge();
    ms_bridge_register_net(response_net, NULL);
    char *response = NULL;
    uint8_t *body = NULL;
    size_t length = 0;
    ms_bridge_invoke_net("{}", response_bytes, sizeof(response_bytes), &response, &body, &length);
    assert(response == response_json && body == response_bytes);
    assert(length == sizeof(response_bytes) && memcmp(body, response_bytes, length) == 0);
}

static pthread_mutex_t call_lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t call_condition = PTHREAD_COND_INITIALIZER;
static int call_entered;
static int call_released;
static int thread_result;

static int blocked_dispatch(const char *action, const char *payload, char *output,
                            size_t capacity, size_t *needed) {
    (void)action; (void)payload; (void)output; (void)capacity; (void)needed;
    assert(pthread_mutex_lock(&call_lock) == 0);
    call_entered = 1;
    assert(pthread_cond_signal(&call_condition) == 0);
    while (!call_released) assert(pthread_cond_wait(&call_condition, &call_lock) == 0);
    assert(pthread_mutex_unlock(&call_lock) == 0);
    return MS_BRIDGE_OK;
}

static void *dispatch_thread(void *unused) {
    (void)unused;
    thread_result = ms_bridge_dispatch("ping", "{}", NULL, 0, NULL);
    return NULL;
}

static void test_in_flight_call_may_finish_after_disable(void) {
    reset_bridge();
    ms_bridge_register_dispatcher(blocked_dispatch);
    pthread_t thread;
    assert(pthread_create(&thread, NULL, dispatch_thread, NULL) == 0);
    assert(pthread_mutex_lock(&call_lock) == 0);
    while (!call_entered) assert(pthread_cond_wait(&call_condition, &call_lock) == 0);
    ms_bridge_set_vm_available(0);
    assert(ms_bridge_dispatch("ping", "{}", NULL, 0, NULL) == MS_BRIDGE_NOT_STARTED);
    ms_bridge_register_dispatcher(NULL);
    assert(ms_bridge_is_vm_available() == 0);
    call_released = 1;
    assert(pthread_cond_signal(&call_condition) == 0);
    assert(pthread_mutex_unlock(&call_lock) == 0);
    assert(pthread_join(thread, NULL) == 0);
    assert(thread_result == MS_BRIDGE_OK);
}

static int owned_calls;
static int owned_response(const char *action, const char *payload, char **output, size_t *length) {
    assert(action && payload && output && length && *output == NULL && *length == 0);
    assert(ms_bridge_is_vm_available() == 1); /* No bridge lock around callbacks. */
    ++owned_calls;
    const size_t count = 100000;
    *output = malloc(count + 1);
    assert(*output);
    memset(*output, 'a', count);
    (*output)[count] = 0;
    *length = count;
    if (strcmp(action, "error") == 0) return MS_BRIDGE_JAVA_EXCEPTION;
    if (strcmp(action, "oversize") == 0) *length = (size_t)MS_BRIDGE_MAX_RESPONSE_BYTES + 1;
    if (strcmp(action, "nul") == 0) (*output)[8] = 0;
    return MS_BRIDGE_OK;
}

static void test_owned_prefers_one_callback_and_clears_it_on_legacy_replacement(void) {
    reset_bridge(); owned_calls = 0;
    ms_bridge_register_dispatchers(response_dispatch, owned_response);
    char *output = NULL; size_t length = 0;
    assert(ms_bridge_dispatch_owned("large", "{}", &output, &length) == MS_BRIDGE_OK);
    assert(length == 100000 && output[length] == 0 && owned_calls == 1 && dispatch_calls == 0);
    ms_bridge_free_string(output);
    ms_bridge_register_dispatcher(response_dispatch);
    assert(ms_bridge_dispatch_owned("small", "{}", &output, &length) == MS_BRIDGE_OK);
    assert(strcmp(output, "{\"ok\":true}") == 0 && length == 11 && owned_calls == 1 && dispatch_calls == 1);
    ms_bridge_free_string(output);
}

static void test_owned_errors_limits_and_embedded_nul_release_allocation(void) {
    reset_bridge(); owned_calls = 0;
    ms_bridge_register_dispatchers(NULL, owned_response);
    const char *actions[] = {"error", "oversize", "nul"};
    const int expected[] = {MS_BRIDGE_JAVA_EXCEPTION, MS_BRIDGE_BUFFER_TOO_SMALL, MS_BRIDGE_INVALID_RESPONSE};
    for (size_t i = 0; i < 3; ++i) {
        char *output = (char *)1; size_t length = 99;
        assert(ms_bridge_dispatch_owned(actions[i], "{}", &output, &length) == expected[i]);
        assert(output == NULL && length == 0 && owned_calls == (int)i + 1);
    }
}

static void test_owned_availability_and_invalid_inputs_do_not_dispatch(void) {
    reset_bridge(); owned_calls = 0;
    ms_bridge_register_dispatchers(NULL, owned_response);
    char *output = (char *)1; size_t length = 99;
    assert(ms_bridge_dispatch_owned(NULL, "{}", &output, &length) == MS_BRIDGE_INVALID_ARG);
    assert(output == NULL && length == 0 && owned_calls == 0);
    assert(ms_bridge_dispatch_owned("ping", "{}", NULL, &length) == MS_BRIDGE_INVALID_ARG);
    assert(ms_bridge_dispatch_owned("ping", "{}", &output, NULL) == MS_BRIDGE_INVALID_ARG);
    ms_bridge_set_vm_available(0);
    assert(ms_bridge_dispatch_owned("ping", "{}", &output, &length) == MS_BRIDGE_NOT_STARTED);
    ms_bridge_set_vm_available(1);
    assert(ms_bridge_is_vm_available() == 1);
    ms_bridge_register_dispatcher(NULL);
    ms_bridge_set_vm_available(1);
    assert(ms_bridge_dispatch_owned("ping", "{}", &output, &length) == MS_BRIDGE_NOT_STARTED);
    assert(output == NULL && length == 0 && owned_calls == 0);
}

int main(void) {
    test_absent_dispatcher_cannot_be_enabled();
    test_lifecycle_stops_subsequent_calls();
    test_dispatch_outputs_are_initialized();
    test_dispatch_rejects_invalid_inputs_without_callback();
    test_dispatch_preserves_callback_results();
    test_network_outputs_are_initialized();
    test_network_rejects_invalid_inputs_without_callback();
    test_network_preserves_callback_outputs();
    test_in_flight_call_may_finish_after_disable();
    test_owned_prefers_one_callback_and_clears_it_on_legacy_replacement();
    test_owned_errors_limits_and_embedded_nul_release_allocation();
    test_owned_availability_and_invalid_inputs_do_not_dispatch();
    reset_bridge();
    puts("PASS: 12 native bridge regression tests");
    return 0;
}
