#include "include/MSJNIBridge.h"
#include <string.h>
#include <stdlib.h>
#include <stdio.h>
#include <pthread.h>

static ms_bridge_net_fn g_net_handler = NULL;
static ms_bridge_free_fn g_free_fn = NULL;
static ms_bridge_channel_fn g_channel_handler = NULL;
static ms_bridge_dispatch_fn g_dispatcher = NULL;
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
    pthread_mutex_lock(&g_bridge_lock);
    g_dispatcher = dispatcher;
    if (dispatcher != NULL) {
        g_vm_available = 1;
    }
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
    g_vm_available = available;
    pthread_mutex_unlock(&g_bridge_lock);
}

int ms_bridge_dispatch(const char *action,
                       const char *payload_json,
                       char *output,
                       size_t capacity,
                       size_t *needed) {
    if (!action || !payload_json) {
        return MS_BRIDGE_INVALID_ARG;
    }

    pthread_mutex_lock(&g_bridge_lock);
    ms_bridge_dispatch_fn fn = g_dispatcher;
    pthread_mutex_unlock(&g_bridge_lock);

    if (fn) {
        return fn(action, payload_json, output, capacity, needed);
    }

    /* If no external dispatcher registered, provide safe not-started indicator */
    if (needed) {
        *needed = 0;
    }
    return MS_BRIDGE_NOT_STARTED;
}

void ms_bridge_invoke_net(const char *req_json,
                          const uint8_t *req_body,
                          size_t req_body_len,
                          char **out_resp_json,
                          uint8_t **out_resp_body,
                          size_t *out_resp_body_len) {
    pthread_mutex_lock(&g_bridge_lock);
    ms_bridge_net_fn fn = g_net_handler;
    pthread_mutex_unlock(&g_bridge_lock);

    if (fn) {
        fn(req_json, req_body, req_body_len, out_resp_json, out_resp_body, out_resp_body_len);
    } else {
        if (out_resp_json) *out_resp_json = NULL;
        if (out_resp_body) *out_resp_body = NULL;
        if (out_resp_body_len) *out_resp_body_len = 0;
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
