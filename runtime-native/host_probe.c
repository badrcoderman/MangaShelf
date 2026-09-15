#include "MSJavaRuntime.h"
#include <stdio.h>
#include <string.h>
#include <pthread.h>
static const char *plugin, *directory;
static int worker_result;
static void *worker(void *unused) {
    (void)unused;
    char output[1024]; size_t needed;
    worker_result = ms_java_call_string2("mangashelf/probe/RuntimeProbe", "run", plugin, directory, output, sizeof(output), &needed);
    if (!worker_result) puts(output);
    return NULL;
}
int main(int argc, char **argv) {
    if (argc != 5) return 2;
    int status = ms_java_start(JNI_CreateJavaVM, argv[1], argv[2]);
    if (status) { fprintf(stderr, "JVM start failed: %d\n", status); return status; }
    plugin = argv[3]; directory = argv[4];
    pthread_t thread;
    if (pthread_create(&thread, NULL, worker, NULL)) return 9;
    if (pthread_join(thread, NULL)) return 10;
    if (worker_result) return worker_result;
    char output[16]; size_t needed;
    /* A failed lookup must not poison subsequent JNI calls on the same process. */
    int missing = ms_java_call_string2("missing/Class", "run", "", "", output, sizeof(output), &needed);
    if (missing != MS_JAVA_EXCEPTION) return 11;
    worker(NULL);
    return worker_result;
}
