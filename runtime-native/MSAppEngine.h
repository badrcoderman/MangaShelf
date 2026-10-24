#ifndef MS_APP_ENGINE_H
#define MS_APP_ENGINE_H
#ifdef __cplusplus
extern "C" {
#endif

/* Plain C application boundary; Swift never imports JNI's function tables.
 * Call on a worker. This starts one process-lifetime interpreter VM and installs
 * the app-owned SourceRuntime entrypoint. Configure its services before loading
 * a package. A nonzero status requires reporting failure, never retrying VM creation.
 * Values below 100 are MS_JAVA_*; values >=100 are 100 + MS_BRIDGE_*.
 */
int ms_app_engine_is_compiled(void);
int ms_app_engine_start(const char *java_home, const char *classpath, const char *temporary_directory);

#ifdef __cplusplus
}
#endif
#endif
