#ifndef MS_JAVA_RUNTIME_H
#define MS_JAVA_RUNTIME_H
#include <stddef.h>
#include <jni.h>
#ifdef __cplusplus
extern "C" {
#endif
/* Process-lifetime JVM. Call off the UI thread. Function pointer selects the linked VM. */
typedef jint (JNICALL *ms_create_vm_fn)(JavaVM **, void **, void *);
int ms_java_start(ms_create_vm_fn create_vm, const char *classpath, const char *java_home);
/* Calls a static (String,String)->String method. Uses UTF-8, never Modified UTF-8 for arguments. */
int ms_java_call_string2(const char *class_name, const char *method_name,
                         const char *first, const char *second,
                         char *output, size_t capacity, size_t *needed);
enum { MS_JAVA_OK=0, MS_JAVA_ARGUMENT=1, MS_JAVA_MEMORY=2,
       MS_JAVA_START_FAILED=3, MS_JAVA_NOT_STARTED=4, MS_JAVA_EXCEPTION=5,
       MS_JAVA_BUFFER=6, MS_JAVA_THREAD=7, MS_JAVA_ALREADY_STARTED=8 };
#ifdef __cplusplus
}
#endif
#endif
