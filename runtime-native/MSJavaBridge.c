#include "MSJavaBridge.h"
#include <pthread.h>
#include <string.h>

enum { CLASS_CAPACITY = 1024, METHOD_CAPACITY = 128 };
static pthread_mutex_t adapter_lock = PTHREAD_MUTEX_INITIALIZER;
static char installed_class[CLASS_CAPACITY];
static char installed_method[METHOD_CAPACITY];
static int installed;
static int active;

static int bridge_status(int status) {
    switch (status) {
        case MS_JAVA_OK: return MS_BRIDGE_OK;
        case MS_JAVA_ARGUMENT: return MS_BRIDGE_INVALID_ARG;
        case MS_JAVA_NOT_STARTED: return MS_BRIDGE_NOT_STARTED;
        case MS_JAVA_CLASS_NOT_FOUND: return MS_BRIDGE_CLASS_NOT_FOUND;
        case MS_JAVA_METHOD_NOT_FOUND: return MS_BRIDGE_METHOD_NOT_FOUND;
        case MS_JAVA_EXCEPTION: return MS_BRIDGE_JAVA_EXCEPTION;
        case MS_JAVA_BUFFER:
        case MS_JAVA_LIMIT: return MS_BRIDGE_BUFFER_TOO_SMALL;
        default: return MS_BRIDGE_JNI_ERROR;
    }
}

int ms_java_bridge_dispatch_owned(const char *action, const char *payload_json,
                                  char **output, size_t *length) {
    if (output) *output = NULL;
    if (length) *length = 0;
    if (!action || !payload_json || !output || !length) return MS_BRIDGE_INVALID_ARG;
    char class_name[CLASS_CAPACITY], method_name[METHOD_CAPACITY];
    pthread_mutex_lock(&adapter_lock);
    int available = installed && active;
    if (available) {
        memcpy(class_name, installed_class, sizeof(class_name));
        memcpy(method_name, installed_method, sizeof(method_name));
    }
    pthread_mutex_unlock(&adapter_lock);
    if (!available) return MS_BRIDGE_NOT_STARTED;
    int result = bridge_status(ms_java_call_string2_owned(class_name, method_name,
                                                         action, payload_json,
                                                         MS_JAVA_MAX_STRING_BYTES,
                                                         output, length));
    if (result == MS_BRIDGE_OK && memchr(*output, 0, *length)) {
        ms_java_free_string(*output);
        *output = NULL;
        *length = 0;
        return MS_BRIDGE_JNI_ERROR;
    }
    return result;
}

static int dispatch_fixed(const char *action, const char *payload_json,
                           char *output, size_t capacity, size_t *needed) {
    if (needed) *needed = 0;
    if (output && capacity) output[0] = 0;
    if ((!output && capacity) || !action || !payload_json) return MS_BRIDGE_INVALID_ARG;
    char *owned = NULL;
    size_t length = 0;
    int result = ms_java_bridge_dispatch_owned(action, payload_json, &owned, &length);
    if (result != MS_BRIDGE_OK) return result;
    if (needed) *needed = length;
    if (length >= capacity) result = MS_BRIDGE_BUFFER_TOO_SMALL;
    else memcpy(output, owned, length + 1);
    ms_java_free_string(owned);
    return result;
}

int ms_java_bridge_install(const char *class_name, const char *method_name) {
    if (!class_name || !*class_name || !method_name || !*method_name ||
        strlen(class_name) >= CLASS_CAPACITY || strlen(method_name) >= METHOD_CAPACITY)
        return MS_BRIDGE_INVALID_ARG;
    /* Resolve without the adapter lock: JVM class initialization may call back
     * into native code. Neither JNIEnv nor Java local references are retained. */
    int result = bridge_status(ms_java_check_string2(class_name, method_name));
    if (result != MS_BRIDGE_OK) return result;
    pthread_mutex_lock(&adapter_lock);
    strcpy(installed_class, class_name);
    strcpy(installed_method, method_name);
    installed = 1;
    active = 1;
    ms_bridge_register_dispatcher(dispatch_fixed);
    pthread_mutex_unlock(&adapter_lock);
    return MS_BRIDGE_OK;
}

void ms_java_bridge_set_active(int enabled) {
    pthread_mutex_lock(&adapter_lock);
    active = installed && enabled != 0;
    ms_bridge_set_vm_available(active);
    pthread_mutex_unlock(&adapter_lock);
}

void ms_java_bridge_uninstall(void) {
    pthread_mutex_lock(&adapter_lock);
    installed = 0;
    active = 0;
    installed_class[0] = 0;
    installed_method[0] = 0;
    ms_bridge_register_dispatcher(NULL);
    pthread_mutex_unlock(&adapter_lock);
}
