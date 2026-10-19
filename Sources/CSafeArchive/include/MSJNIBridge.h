#ifndef MS_JNI_BRIDGE_H
#define MS_JNI_BRIDGE_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Return status codes for extension bridge calls */
enum {
    MS_BRIDGE_OK = 0,
    MS_BRIDGE_BUFFER_TOO_SMALL = 1,
    MS_BRIDGE_CLASS_NOT_FOUND = 2,
    MS_BRIDGE_METHOD_NOT_FOUND = 3,
    MS_BRIDGE_NOT_STARTED = 4,
    MS_BRIDGE_JAVA_EXCEPTION = 5,
    MS_BRIDGE_JNI_ERROR = 6,
    MS_BRIDGE_INVALID_ARG = 7
};

typedef void (*ms_bridge_net_fn)(const char *request_json_utf8,
                                  const uint8_t *body_bytes,
                                  size_t body_len,
                                  char **out_response_json_utf8,
                                  uint8_t **out_body_bytes,
                                  size_t *out_body_len);

typedef void (*ms_bridge_free_fn)(uint8_t *buf, size_t len);

typedef void (*ms_bridge_channel_fn)(const char *topic_utf8, const char *payload_utf8);

typedef int (*ms_bridge_dispatch_fn)(const char *action,
                                     const char *payload_json,
                                     char *output,
                                     size_t capacity,
                                     size_t *needed);

/* Registration functions */
void ms_bridge_register_net(ms_bridge_net_fn handler, ms_bridge_free_fn free_fn);
void ms_bridge_register_channel(ms_bridge_channel_fn handler);
/* Installing a dispatcher enables dispatch; NULL removes it and disables dispatch. */
void ms_bridge_register_dispatcher(ms_bridge_dispatch_fn dispatcher);

/* Availability requires an installed dispatcher. Setting zero disables new calls;
 * setting nonzero enables them only while a dispatcher is installed. Callbacks
 * run outside the registration lock: a previously captured call may finish after
 * disabling or unregistering. The caller must manage callback code lifetime. */
int ms_bridge_is_vm_available(void);
void ms_bridge_set_vm_available(int available);

/* Initializes optional *needed to zero and output[0] to NUL when capacity > 0,
 * including on errors and before calling the dispatcher. NULL output is valid
 * only with zero capacity (a size query); needed is optional. The dispatcher
 * remains responsible for its response bounds and needed-length convention. */
int ms_bridge_dispatch(const char *action,
                       const char *payload_json,
                       char *output,
                       size_t capacity,
                       size_t *needed);

/* Initializes each supplied response output to NULL/zero before invoking the
 * network handler. Outputs remain empty with no handler or invalid input:
 * req_json must be non-NULL, and req_body may be NULL only for an empty body.
 * Output pointers are optional. The handler owns response allocation rules. */
void ms_bridge_invoke_net(const char *req_json,
                          const uint8_t *req_body,
                          size_t req_body_len,
                          char **out_resp_json,
                          uint8_t **out_resp_body,
                          size_t *out_resp_body_len);

/* Triggers registered channel handler (invoked by JNI or tests) */
void ms_bridge_invoke_channel(const char *topic, const char *payload);

#ifdef __cplusplus
}
#endif

#endif /* MS_JNI_BRIDGE_H */
