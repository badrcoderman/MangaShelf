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
    char early[16]; size_t early_needed = 99;
    if (ms_java_call_string2("missing/Class", "run", "", "", early, sizeof(early), &early_needed) != MS_JAVA_NOT_STARTED) return 12;
    if (early_needed != 0 || early[0] != 0) return 13;
    if (ms_java_start(NULL, argv[1], argv[2]) != MS_JAVA_ARGUMENT) return 14;
    int status = ms_java_start(JNI_CreateJavaVM, argv[1], argv[2]);
    if (status) { fprintf(stderr, "JVM start failed: %d\n", status); return status; }
    if (ms_java_start(JNI_CreateJavaVM, argv[1], argv[2]) != MS_JAVA_ALREADY_STARTED) return 15;
    plugin = argv[3]; directory = argv[4];
    pthread_t thread;
    if (pthread_create(&thread, NULL, worker, NULL)) return 9;
    if (pthread_join(thread, NULL)) return 10;
    if (worker_result) return worker_result;
    char output[16]; size_t needed;
    /* Size discovery must be safe with no buffer, and report a useful bound. */
    int small = ms_java_call_string2("mangashelf/probe/RuntimeProbe", "run", plugin, directory, NULL, 0, &needed);
    if (small != MS_JAVA_BUFFER || needed <= sizeof(output)) return 16;
    if (ms_java_call_string2("missing/Class", "run", "", "", NULL, 1, &needed) != MS_JAVA_ARGUMENT) return 17;
    /* A failed lookup must not poison subsequent JNI calls on the same process. */
    int missing = ms_java_call_string2("missing/Class", "run", "", "", output, sizeof(output), &needed);
    if (missing != MS_JAVA_EXCEPTION) return 11;
    worker(NULL);
    return worker_result;
}
