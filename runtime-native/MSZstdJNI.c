/* MangaShelf's independently authored JNI adapter for the pinned public Zstd API.
 * Codec algorithms are built from the separately licensed upstream C sources.
 * Java longs are checked registry IDs, never caller-supplied native addresses.
 */
#include "MSZstdJNI.h"
#include <zstd.h>
#include <limits.h>
#include <pthread.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#ifdef MSL_ZSTD_TESTING
#include <stdatomic.h>
#endif

_Static_assert(sizeof(size_t) == sizeof(jlong), "MSL Zstd requires a 64-bit target");
#define MSL_ZSTD_TABLE ((jlong)0x4d534c5a)
#define MSL_ZSTD_LIMIT 128U

enum ContextKind { COMPRESSOR, DECOMPRESSOR };
struct Context {
    jlong id;
    enum ContextKind kind;
    union { ZSTD_CCtx *compressor; ZSTD_DCtx *decompressor; } codec;
    pthread_mutex_t operation;
    size_t references;
    struct Context *next;
};
struct Metadata {
    jclass compressor;
    jclass decompressor;
    jfieldID compressor_input;
    jfieldID compressor_output;
    jfieldID decompressor_input;
    jfieldID decompressor_output;
};
static pthread_mutex_t registry_lock = PTHREAD_MUTEX_INITIALIZER;
static struct Context *contexts;
static size_t live_contexts;
static jlong next_id = 1;
static struct Metadata metadata;

static void throw_error(JNIEnv *env, const char *type, const char *message) {
    if ((*env)->ExceptionCheck(env)) return;
    jclass clazz = (*env)->FindClass(env, type);
    if (clazz != NULL) {
        (*env)->ThrowNew(env, clazz, message);
        (*env)->DeleteLocalRef(env, clazz);
    }
}
static void illegal_state(JNIEnv *env, const char *message) {
    throw_error(env, "java/lang/IllegalStateException", message);
}

#ifdef MSL_ZSTD_TESTING
/* Compiled only into authored test libraries. No test hooks in the iOS archive. */
static _Thread_local int fault;
static atomic_int global_references;
static int load_kind;
static pthread_mutex_t gate_lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t gate_condition = PTHREAD_COND_INITIALIZER;
static int gate_armed, gate_entered, gate_released;
static int fail_at(int stage) { if (fault != stage) return 0; fault = 0; return 1; }
static void operation_gate(void) {
    pthread_mutex_lock(&gate_lock);
    if (gate_armed) {
        gate_armed = 0; gate_entered = 1;
        while (!gate_released) pthread_cond_wait(&gate_condition, &gate_lock);
    }
    pthread_mutex_unlock(&gate_lock);
}
JNIEXPORT void JNICALL Java_mangashelf_host_ZstdNativeTestHooks_faultNext(JNIEnv *env, jclass type, jint stage) {
    (void)env; (void)type; fault = stage;
}
JNIEXPORT jint JNICALL Java_mangashelf_host_ZstdNativeTestHooks_activeContexts(JNIEnv *env, jclass type) {
    (void)env; (void)type;
    pthread_mutex_lock(&registry_lock); jint value = (jint)live_contexts; pthread_mutex_unlock(&registry_lock);
    return value;
}
JNIEXPORT void JNICALL Java_mangashelf_host_ZstdNativeTestHooks_armGate(JNIEnv *env, jclass type) {
    (void)env; (void)type;
    pthread_mutex_lock(&gate_lock); gate_armed = 1; gate_entered = 0; gate_released = 0; pthread_mutex_unlock(&gate_lock);
}
JNIEXPORT jboolean JNICALL Java_mangashelf_host_ZstdNativeTestHooks_gateEntered(JNIEnv *env, jclass type) {
    (void)env; (void)type;
    pthread_mutex_lock(&gate_lock); int value = gate_entered; pthread_mutex_unlock(&gate_lock);
    return value ? JNI_TRUE : JNI_FALSE;
}
JNIEXPORT void JNICALL Java_mangashelf_host_ZstdNativeTestHooks_releaseGate(JNIEnv *env, jclass type) {
    (void)env; (void)type;
    pthread_mutex_lock(&gate_lock); gate_released = 1; pthread_cond_broadcast(&gate_condition); pthread_mutex_unlock(&gate_lock);
}
JNIEXPORT jint JNICALL Java_mangashelf_host_ZstdNativeTestHooks_loadKind(JNIEnv *env, jclass type) {
    (void)env; (void)type; return load_kind;
}
JNIEXPORT jint JNICALL Java_mangashelf_host_ZstdNativeTestHooks_globalReferences(JNIEnv *env, jclass type) {
    (void)env; (void)type; return atomic_load(&global_references);
}
JNIEXPORT jint JNICALL Java_mangashelf_host_ZstdNativeTestHooks_shutdown(JNIEnv *env, jclass type) {
    (void)type; return msl_zstd_shutdown(env);
}
#else
static int fail_at(int stage) { (void)stage; return 0; }
static void operation_gate(void) { }
#endif

static jclass global_class(JNIEnv *env, jclass value, int stage) {
    if (fail_at(stage)) { throw_error(env, "java/lang/OutOfMemoryError", "zstd_class_reference"); return NULL; }
    jclass result = fail_at(7) ? NULL : (*env)->NewGlobalRef(env, value);
    if (result == NULL) throw_error(env, "java/lang/OutOfMemoryError", "zstd_class_reference");
#ifdef MSL_ZSTD_TESTING
    if (result != NULL) atomic_fetch_add(&global_references, 1);
#endif
    return result;
}
static void delete_global_class(JNIEnv *env, jclass value) {
    if (value == NULL) return;
    (*env)->DeleteGlobalRef(env, value);
#ifdef MSL_ZSTD_TESTING
    atomic_fetch_sub(&global_references, 1);
#endif
}

static void delete_metadata(JNIEnv *env, struct Metadata *value) {
    delete_global_class(env, value->compressor);
    delete_global_class(env, value->decompressor);
    memset(value, 0, sizeof(*value));
}
static int initialize_metadata(JNIEnv *env) {
    pthread_mutex_lock(&registry_lock);
    int ready = metadata.compressor != NULL;
    pthread_mutex_unlock(&registry_lock);
    if (ready) return 1;
    struct Metadata prepared = {0};
    jclass compressor = (*env)->FindClass(env, "com/squareup/zstd/ZstdCompressor");
    if (compressor == NULL) { throw_error(env, "java/lang/OutOfMemoryError", "zstd_metadata_class"); return 0; }
    jclass decompressor = (*env)->FindClass(env, "com/squareup/zstd/ZstdDecompressor");
    if (decompressor == NULL) {
        throw_error(env, "java/lang/OutOfMemoryError", "zstd_metadata_class");
        (*env)->DeleteLocalRef(env, compressor); return 0;
    }
    prepared.compressor_input = (*env)->GetFieldID(env, compressor, fail_at(6) ? "authored_missing_field" : "inputBytesProcessed", "I");
    if (prepared.compressor_input == NULL) goto failed;
    prepared.compressor_output = (*env)->GetFieldID(env, compressor, "outputBytesProcessed", "I");
    if (prepared.compressor_output == NULL) goto failed;
    prepared.decompressor_input = (*env)->GetFieldID(env, decompressor, "inputBytesProcessed", "I");
    if (prepared.decompressor_input == NULL) goto failed;
    prepared.decompressor_output = (*env)->GetFieldID(env, decompressor, "outputBytesProcessed", "I");
    if (prepared.decompressor_output == NULL) goto failed;
    prepared.compressor = global_class(env, compressor, 4);
    if (prepared.compressor == NULL) goto failed;
    prepared.decompressor = global_class(env, decompressor, 5);
    if (prepared.decompressor == NULL) goto failed;
    pthread_mutex_lock(&registry_lock);
    if (metadata.compressor == NULL) { metadata = prepared; memset(&prepared, 0, sizeof(prepared)); }
    pthread_mutex_unlock(&registry_lock);
    delete_metadata(env, &prepared);
    (*env)->DeleteLocalRef(env, compressor); (*env)->DeleteLocalRef(env, decompressor);
    return 1;
failed:
    throw_error(env, "java/lang/OutOfMemoryError", "zstd_metadata_lookup");
    delete_metadata(env, &prepared);
    (*env)->DeleteLocalRef(env, compressor); (*env)->DeleteLocalRef(env, decompressor);
    return 0;
}

static void dispose_context(struct Context *context) {
    if (context->kind == COMPRESSOR) ZSTD_freeCCtx(context->codec.compressor);
    else ZSTD_freeDCtx(context->codec.decompressor);
    pthread_mutex_destroy(&context->operation);
    free(context);
}
static struct Context *acquire_context(JNIEnv *env, jlong id, enum ContextKind kind) {
    struct Context *found;
    pthread_mutex_lock(&registry_lock);
    for (found = contexts; found != NULL && found->id != id; found = found->next) { }
    if (found != NULL && found->kind == kind) found->references++;
    else found = NULL;
    pthread_mutex_unlock(&registry_lock);
    if (found == NULL) illegal_state(env, "zstd_context_closed_or_invalid");
    else pthread_mutex_lock(&found->operation);
    return found;
}
static void release_context(struct Context *context) {
    pthread_mutex_unlock(&context->operation);
    pthread_mutex_lock(&registry_lock);
    int dispose = --context->references == 0;
    if (dispose) live_contexts--;
    pthread_mutex_unlock(&registry_lock);
    if (dispose) dispose_context(context);
}
static void close_context(jlong id, enum ContextKind kind) {
    struct Context *found = NULL;
    int dispose = 0;
    pthread_mutex_lock(&registry_lock);
    struct Context **cursor = &contexts;
    while (*cursor != NULL && (*cursor)->id != id) cursor = &(*cursor)->next;
    if (*cursor != NULL && (*cursor)->kind == kind) {
        found = *cursor; *cursor = found->next;
        dispose = --found->references == 0;
        if (dispose) live_contexts--;
    }
    pthread_mutex_unlock(&registry_lock);
    if (dispose) dispose_context(found);
}
static jlong create_context(JNIEnv *env, enum ContextKind kind) {
    if (!initialize_metadata(env)) return 0;
    struct Context *context = fail_at(1) ? NULL : calloc(1, sizeof(*context));
    if (context == NULL) { throw_error(env, "java/lang/OutOfMemoryError", "zstd_context_allocation"); return 0; }
    context->kind = kind;
    if (pthread_mutex_init(&context->operation, NULL) != 0) {
        free(context); illegal_state(env, "zstd_context_mutex"); return 0;
    }
    int allocated;
    if (kind == COMPRESSOR) { context->codec.compressor = ZSTD_createCCtx(); allocated = context->codec.compressor != NULL; }
    else { context->codec.decompressor = ZSTD_createDCtx(); allocated = context->codec.decompressor != NULL; }
    if (!allocated) { dispose_context(context); throw_error(env, "java/lang/OutOfMemoryError", "zstd_codec_allocation"); return 0; }
    if (kind == DECOMPRESSOR && ZSTD_isError(ZSTD_DCtx_setParameter(context->codec.decompressor, ZSTD_d_windowLogMax, 26))) {
        dispose_context(context); illegal_state(env, "zstd_window_limit_configuration"); return 0;
    }
    pthread_mutex_lock(&registry_lock);
    if (live_contexts >= MSL_ZSTD_LIMIT || next_id == LLONG_MAX) {
        pthread_mutex_unlock(&registry_lock); dispose_context(context); illegal_state(env, "zstd_context_limit"); return 0;
    }
    context->id = next_id++; context->references = 1; context->next = contexts;
    contexts = context; live_contexts++;
    jlong id = context->id;
    pthread_mutex_unlock(&registry_lock);
    return id;
}

static jbyte *array_elements(JNIEnv *env, jbyteArray array, int stage) {
    if (fail_at(stage)) { throw_error(env, "java/lang/OutOfMemoryError", "zstd_array_acquisition"); return NULL; }
    jbyte *elements = (*env)->GetByteArrayElements(env, array, NULL);
    if (elements == NULL) throw_error(env, "java/lang/OutOfMemoryError", "zstd_array_acquisition");
    return elements;
}
static jlong stream(JNIEnv *env, jobject receiver, jlong table, jlong handle,
                    jbyteArray output, jint output_end, jint output_start,
                    jbyteArray input, jint input_end, jint input_start, jint mode, enum ContextKind kind) {
    if (table != MSL_ZSTD_TABLE) { illegal_state(env, "zstd_metadata_invalid"); return 0; }
    if (output == NULL || input == NULL) { throw_error(env, "java/lang/NullPointerException", "zstd_array_null"); return 0; }
    jsize output_length = (*env)->GetArrayLength(env, output);
    jsize input_length = (*env)->GetArrayLength(env, input);
    if (input_start < 0 || input_end < input_start || input_end > input_length ||
        output_start < 0 || output_end < output_start || output_end > output_length) {
        throw_error(env, "java/lang/IndexOutOfBoundsException", "zstd_array_bounds"); return 0;
    }
    if (mode < ZSTD_e_continue || mode > ZSTD_e_end) {
        throw_error(env, "java/lang/IllegalArgumentException", "zstd_stream_mode"); return 0;
    }
    if ((*env)->IsSameObject(env, input, output) && input_start < output_end && output_start < input_end) {
        throw_error(env, "java/lang/IllegalArgumentException", "zstd_array_overlap"); return 0;
    }
    struct Context *context = acquire_context(env, handle, kind);
    if (context == NULL) return 0;
    pthread_mutex_lock(&registry_lock);
    jfieldID input_field = kind == COMPRESSOR ? metadata.compressor_input : metadata.decompressor_input;
    jfieldID output_field = kind == COMPRESSOR ? metadata.compressor_output : metadata.decompressor_output;
    pthread_mutex_unlock(&registry_lock);
    if (input_field == NULL || output_field == NULL) { release_context(context); illegal_state(env, "zstd_metadata_unavailable"); return 0; }
    operation_gate();
    (*env)->SetIntField(env, receiver, input_field, 0); (*env)->SetIntField(env, receiver, output_field, 0);
    jbyte *input_bytes = array_elements(env, input, 2);
    if (input_bytes == NULL) { release_context(context); return 0; }
    jbyte *output_bytes = array_elements(env, output, 3);
    if (output_bytes == NULL) {
        (*env)->ReleaseByteArrayElements(env, input, input_bytes, JNI_ABORT);
        release_context(context); return 0;
    }
    ZSTD_inBuffer in = {input_bytes, (size_t)input_end, (size_t)input_start};
    ZSTD_outBuffer out = {output_bytes, (size_t)output_end, (size_t)output_start};
    size_t result = kind == COMPRESSOR ? ZSTD_compressStream2(context->codec.compressor, &out, &in, (ZSTD_EndDirective)mode) :
                                       ZSTD_decompressStream(context->codec.decompressor, &out, &in);
    (*env)->ReleaseByteArrayElements(env, input, input_bytes, JNI_ABORT);
    (*env)->ReleaseByteArrayElements(env, output, output_bytes, 0);
    (*env)->SetIntField(env, receiver, input_field, (jint)in.pos - input_start);
    (*env)->SetIntField(env, receiver, output_field, (jint)out.pos - output_start);
    release_context(context);
    return (jlong)result;
}

JNIEXPORT jlong JNICALL Java_com_squareup_zstd_JniZstdKt_createJniZstd(JNIEnv *env, jclass type) {
    (void)type; return initialize_metadata(env) ? MSL_ZSTD_TABLE : 0;
}
JNIEXPORT jstring JNICALL Java_com_squareup_zstd_JniZstdKt_jniGetErrorName(JNIEnv *env, jclass type, jlong code) {
    (void)type;
    if (!ZSTD_isError((size_t)code)) return NULL;
    jstring result = fail_at(8) ? NULL : (*env)->NewStringUTF(env, ZSTD_getErrorName((size_t)code));
    if (result == NULL) throw_error(env, "java/lang/OutOfMemoryError", "zstd_error_string");
    return result;
}
JNIEXPORT jlong JNICALL Java_com_squareup_zstd_JniZstdKt_createZstdCompressor(JNIEnv *env, jclass type) {
    (void)type; return create_context(env, COMPRESSOR);
}
JNIEXPORT jlong JNICALL Java_com_squareup_zstd_JniZstdKt_createZstdDecompressor(JNIEnv *env, jclass type) {
    (void)type; return create_context(env, DECOMPRESSOR);
}
JNIEXPORT jlong JNICALL Java_com_squareup_zstd_JniZstdCompressor_setParameter(JNIEnv *env, jobject type, jlong handle, jint parameter, jint value) {
    (void)type; struct Context *context = acquire_context(env, handle, COMPRESSOR);
    if (context == NULL) return 0;
    size_t result = ZSTD_CCtx_setParameter(context->codec.compressor, (ZSTD_cParameter)parameter, value);
    release_context(context); return (jlong)result;
}
JNIEXPORT jlong JNICALL Java_com_squareup_zstd_JniZstdCompressor_compressStream2(JNIEnv *env, jobject type, jlong table, jlong handle,
    jbyteArray output, jint output_end, jint output_start, jbyteArray input, jint input_end, jint input_start, jint mode) {
    return stream(env, type, table, handle, output, output_end, output_start, input, input_end, input_start, mode, COMPRESSOR);
}
JNIEXPORT jlong JNICALL Java_com_squareup_zstd_JniZstdDecompressor_decompressStream(JNIEnv *env, jobject type, jlong table, jlong handle,
    jbyteArray output, jint output_end, jint output_start, jbyteArray input, jint input_end, jint input_start) {
    return stream(env, type, table, handle, output, output_end, output_start, input, input_end, input_start, ZSTD_e_continue, DECOMPRESSOR);
}
JNIEXPORT void JNICALL Java_com_squareup_zstd_JniZstdCompressor_close(JNIEnv *env, jobject type, jlong handle) {
    (void)env; (void)type; close_context(handle, COMPRESSOR);
}
JNIEXPORT void JNICALL Java_com_squareup_zstd_JniZstdDecompressor_close(JNIEnv *env, jobject type, jlong handle) {
    (void)env; (void)type; close_context(handle, DECOMPRESSOR);
}

int msl_zstd_shutdown(JNIEnv *env) {
    if (env == NULL) return JNI_ERR;
    pthread_mutex_lock(&registry_lock);
    size_t registered = 0;
    for (struct Context *context = contexts; context != NULL; context = context->next) {
        if (context->references != 1) { pthread_mutex_unlock(&registry_lock); return JNI_ERR; }
        registered++;
    }
    if (registered != live_contexts) { pthread_mutex_unlock(&registry_lock); return JNI_ERR; }
    struct Context *remaining = contexts; struct Metadata owned = metadata;
    contexts = NULL; live_contexts = 0; memset(&metadata, 0, sizeof(metadata));
    pthread_mutex_unlock(&registry_lock);
    while (remaining != NULL) { struct Context *next = remaining->next; dispose_context(remaining); remaining = next; }
    delete_metadata(env, &owned);
    return JNI_OK;
}
JNIEXPORT jint JNICALL JNI_OnLoad_mslzstd(JavaVM *vm, void *reserved) {
    (void)vm; (void)reserved;
#ifdef MSL_ZSTD_TESTING
    load_kind = 2;
#endif
    return JNI_VERSION_1_8;
}
JNIEXPORT void JNICALL JNI_OnUnload_mslzstd(JavaVM *vm, void *reserved) {
    (void)reserved; JNIEnv *env = NULL;
    if ((*vm)->GetEnv(vm, (void **)&env, JNI_VERSION_1_8) == JNI_OK) (void)msl_zstd_shutdown(env);
}
#ifndef MSL_ZSTD_STATIC
JNIEXPORT jint JNICALL JNI_OnLoad(JavaVM *vm, void *reserved) {
    jint version = JNI_OnLoad_mslzstd(vm, reserved);
#ifdef MSL_ZSTD_TESTING
    load_kind = 1;
#endif
    return version;
}
JNIEXPORT void JNICALL JNI_OnUnload(JavaVM *vm, void *reserved) { JNI_OnUnload_mslzstd(vm, reserved); }
#endif
