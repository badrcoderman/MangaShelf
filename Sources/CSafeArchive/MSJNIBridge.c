#include "include/MSJNIBridge.h"
#include <string.h>
#include <stdlib.h>
#include <stdio.h>
#include <pthread.h>

static ms_bridge_net_fn g_net_handler = NULL;
static ms_bridge_free_fn g_free_fn = NULL;
static ms_bridge_channel_fn g_channel_handler = NULL;
static ms_bridge_dispatch_fn g_dispatcher = NULL;
static ms_bridge_owned_dispatch_fn g_owned_dispatcher = NULL;
static int g_vm_available = 0;
static pthread_mutex_t g_bridge_lock = PTHREAD_MUTEX_INITIALIZER;

void ms_bridge_register_net(ms_bridge_net_fn handler, ms_bridge_free_fn free_fn) {
    pthread_mutex_lock(&g_bridge_lock);
    g_net_handler = handler;
    g_free_fn = free_fn;
    pthread_mutex_unlock(&g_bridge_lock);
}

void ms_bridge_register_channel(ms_bridge_channel_fn handler) {
    pthread_mutex_lock(&g_bridge_lock);
    g_channel_handler = handler;
    pthread_mutex_unlock(&g_bridge_lock);
}

void ms_bridge_register_dispatcher(ms_bridge_dispatch_fn dispatcher) {
    ms_bridge_register_dispatchers(dispatcher, NULL);
}

void ms_bridge_register_dispatchers(ms_bridge_dispatch_fn dispatcher, ms_bridge_owned_dispatch_fn owned) {
    pthread_mutex_lock(&g_bridge_lock);
    g_dispatcher = dispatcher;
    g_owned_dispatcher = owned;
    g_vm_available = dispatcher != NULL || owned != NULL;
    pthread_mutex_unlock(&g_bridge_lock);
}

int ms_bridge_is_vm_available(void) {
    pthread_mutex_lock(&g_bridge_lock);
    int avail = g_vm_available;
    pthread_mutex_unlock(&g_bridge_lock);
    return avail;
}

void ms_bridge_set_vm_available(int available) {
    pthread_mutex_lock(&g_bridge_lock);
    g_vm_available = available != 0 && (g_dispatcher != NULL || g_owned_dispatcher != NULL);
    pthread_mutex_unlock(&g_bridge_lock);
}

int ms_bridge_dispatch(const char *action,
                       const char *payload_json,
                       char *output,
                       size_t capacity,
                       size_t *needed) {
    if (needed) {
        *needed = 0;
    }
    if (output && capacity > 0) {
        output[0] = '\0';
    }
    if (!action || !payload_json || (!output && capacity > 0)) {
        return MS_BRIDGE_INVALID_ARG;
    }

    pthread_mutex_lock(&g_bridge_lock);
    ms_bridge_dispatch_fn fn = g_vm_available ? g_dispatcher : NULL;
    pthread_mutex_unlock(&g_bridge_lock);

    if (fn) {
        return fn(action, payload_json, output, capacity, needed);
    }

    return MS_BRIDGE_NOT_STARTED;
}

int ms_bridge_dispatch_owned(const char *action, const char *payload_json,
                             char **output, size_t *length) {
    if (output) *output = NULL;
    if (length) *length = 0;
    if (!action || !payload_json || !output || !length) return MS_BRIDGE_INVALID_ARG;
    pthread_mutex_lock(&g_bridge_lock);
    ms_bridge_owned_dispatch_fn owned = g_vm_available ? g_owned_dispatcher : NULL;
    ms_bridge_dispatch_fn fixed = g_vm_available ? g_dispatcher : NULL;
    pthread_mutex_unlock(&g_bridge_lock);
    if (!owned && !fixed) return MS_BRIDGE_NOT_STARTED;

    char *bytes = NULL;
    size_t count = 0;
    int result;
    if (owned) {
        result = owned(action, payload_json, &bytes, &count);
        if (result == MS_BRIDGE_OK) {
            if (count > (size_t)MS_BRIDGE_MAX_RESPONSE_BYTES) result = MS_BRIDGE_BUFFER_TOO_SMALL;
            else if (!bytes || bytes[count] != 0 || memchr(bytes, 0, count)) result = MS_BRIDGE_INVALID_RESPONSE;
        }
    } else {
        /* Compatibility for explicit old callback users. This is a single
         * invocation, not a size query followed by a repeated command. */
        const size_t capacity = 16384;
        bytes = calloc(capacity, 1);
        if (!bytes) return MS_BRIDGE_JNI_ERROR;
        size_t needed = 0;
        result = fixed(action, payload_json, bytes, capacity, &needed);
        if (result == MS_BRIDGE_OK) {
            const char *end = memchr(bytes, 0, capacity);
            if (needed > capacity || !end) result = MS_BRIDGE_INVALID_RESPONSE;
            else count = (size_t)(end - bytes);
        }
    }
    if (result != MS_BRIDGE_OK) { free(bytes); return result; }
    *output = bytes;
    *length = count;
    return MS_BRIDGE_OK;
}

void ms_bridge_free_string(char *output) { free(output); }

void ms_bridge_invoke_net(const char *req_json,
                          const uint8_t *req_body,
                          size_t req_body_len,
                          char **out_resp_json,
                          uint8_t **out_resp_body,
                          size_t *out_resp_body_len) {
    if (out_resp_json) *out_resp_json = NULL;
    if (out_resp_body) *out_resp_body = NULL;
    if (out_resp_body_len) *out_resp_body_len = 0;
    if (!req_json || (!req_body && req_body_len > 0)) {
        return;
    }

    pthread_mutex_lock(&g_bridge_lock);
    ms_bridge_net_fn fn = g_net_handler;
    pthread_mutex_unlock(&g_bridge_lock);

    if (fn) {
        fn(req_json, req_body, req_body_len, out_resp_json, out_resp_body, out_resp_body_len);
    }
}

void ms_bridge_invoke_channel(const char *topic, const char *payload) {
    pthread_mutex_lock(&g_bridge_lock);
    ms_bridge_channel_fn fn = g_channel_handler;
    pthread_mutex_unlock(&g_bridge_lock);

    if (fn && topic && payload) {
        fn(topic, payload);
    }
}
