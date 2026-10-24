#include "MSAppEngine.h"

#ifndef MSL_APP_ENGINE_ENABLED
#define MSL_APP_ENGINE_ENABLED 0
#endif

#if MSL_APP_ENGINE_ENABLED
#include "MSJavaBridge.h"

int ms_app_engine_is_compiled(void) { return 1; }

int ms_app_engine_start(const char *java_home, const char *classpath, const char *temporary_directory) {
    if (!temporary_directory || !*temporary_directory) return MS_JAVA_ARGUMENT;
    int result = ms_java_start_config(JNI_CreateJavaVM, classpath, java_home, temporary_directory, "");
    if (result != MS_JAVA_OK) return result;
    result = ms_java_bridge_install("mangashelf/host/SourceRuntime", "dispatch");
    return result == MS_BRIDGE_OK ? 0 : 100 + result;
}
#else
int ms_app_engine_is_compiled(void) { return 0; }
int ms_app_engine_start(const char *java_home, const char *classpath, const char *temporary_directory) {
    (void)java_home; (void)classpath; (void)temporary_directory;
    return 4; /* MS_JAVA_NOT_STARTED: this build contains no linked VM. */
}
#endif
