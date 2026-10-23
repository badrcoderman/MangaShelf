#ifndef MS_JAVA_BRIDGE_H
#define MS_JAVA_BRIDGE_H

#include "MSJavaRuntime.h"
#include "MSJNIBridge.h"

#ifdef __cplusplus
extern "C" {
#endif

/* Experimental, explicit connection between the native callback bridge and an
 * app-owned static Java (String,String)->String backend on the VM classpath. Start the process VM
 * with ms_java_start first, then install on a background worker. Installing only
 * resolves the target; it does not establish extension trust or source ABI
 * compatibility. No backend class name is selected implicitly.
 *
 * This adapter owns the ms_bridge dispatcher registration while installed.
 * Lifecycle calls can disable new snapshots; already captured calls may finish.
 * They do not stop, restart, unload or cancel the process-lifetime VM/Java work.
 * UI/background-task scheduling remains the embedding application's job.
 */
int ms_java_bridge_install(const char *class_name, const char *method_name);
void ms_java_bridge_set_active(int active);
void ms_java_bridge_uninstall(void);

/* Executes exactly once and returns a native-owned response, length excluding
 * its trailing NUL. Embedded NUL is rejected by this JSON/C-string adapter.
 * Outputs are NULL/zero on error. Release success with ms_java_free_string.
 * Responses are bounded by MS_JAVA_MAX_STRING_BYTES. Return codes are MS_BRIDGE_*.
 * CLASS_NOT_FOUND denotes class resolution failure, including unavailable
 * dependencies or a prior initialization failure; it does not prove that the
 * named backend class itself is missing.
 *
 * The installed legacy ms_bridge_dispatch callback also executes only once.
 * Its needed value excludes NUL. BUFFER_TOO_SMALL discards the finished result;
 * it is not an invitation to replay an action with a larger buffer.
 */
int ms_java_bridge_dispatch_owned(const char *action, const char *payload_json,
                                  char **output, size_t *length);

#ifdef __cplusplus
}
#endif
#endif
