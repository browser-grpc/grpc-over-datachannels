/* JNI shim over libgrpc_dc for grpcdc.StructDc.
 * JDK 17 has no stable FFI, so the JVM languages reach the
 * shared Rust struct codec (C ABI in libgrpc_dc) through these
 * thin native methods. One symbol serves the Java class and the
 * Kotlin object (same JNI name); the Scala object lives on
 * StructDc$ and gets the _00024-escaped alias.
 *
 * The Rust library is dlopen'ed (GRPCDC_STRUCTDC_LIB, else
 * "libgrpc_dc.so") so this shim has no link-time dependency.
 *
 * Build (Linux):
 *   cc -shared -fPIC \
 *     -I$JAVA_HOME/include -I$JAVA_HOME/include/linux \
 *     java/jni/structdc_jni.c -ldl \
 *     -o libgrpcdc_structdc_jni.so
 *
 * SPDX-License-Identifier: Apache-2.0
 */
#include <jni.h>
#include <dlfcn.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

typedef int (*transcode_fn)(const uint8_t *, size_t, const uint8_t *, size_t,
                            const uint8_t *, size_t, uint8_t **, size_t *,
                            char **);
typedef void (*bytes_free_fn)(uint8_t *, size_t);
typedef void (*error_free_fn)(char *);

static void *lib_handle(void) {
    static void *h;
    if (!h) {
        const char *path = getenv("GRPCDC_STRUCTDC_LIB");
        h = dlopen(path && *path ? path : "libgrpc_dc.so", RTLD_NOW);
    }
    return h;
}

static void *lib_sym(const char *name) {
    void *h = lib_handle();
    return h ? dlsym(h, name) : NULL;
}

static void throw_ise(JNIEnv *env, const char *message) {
    jclass cls = (*env)->FindClass(env, "java/lang/IllegalStateException");
    if (cls) {
        (*env)->ThrowNew(env, cls, message);
    }
}

static jbyteArray transcode(JNIEnv *env, jboolean encode, jbyteArray desc,
                            jbyteArray type, jbyteArray input) {
    transcode_fn fn = (transcode_fn)lib_sym(
        encode ? "grpcdc_struct_encode" : "grpcdc_struct_decode");
    if (!fn) {
        throw_ise(env, "libgrpc_dc struct codec not loadable");
        return NULL;
    }
    bytes_free_fn free_bytes = (bytes_free_fn)lib_sym("grpcdc_struct_free");
    error_free_fn free_error =
        (error_free_fn)lib_sym("grpcdc_struct_error_free");

    if (!desc || !type || !input) {
        throw_ise(env, "struct codec: null array argument");
        return NULL;
    }
    jsize desc_len = (*env)->GetArrayLength(env, desc);
    jsize type_len = (*env)->GetArrayLength(env, type);
    jsize input_len = (*env)->GetArrayLength(env, input);
    uint8_t *out = NULL;
    size_t out_len = 0;
    char *err = NULL;
    /* GetPrimitiveArrayCritical pins the arrays for the call;
       the Rust side only reads them. */
    uint8_t *desc_p = (*env)->GetPrimitiveArrayCritical(env, desc, NULL);
    uint8_t *type_p = (*env)->GetPrimitiveArrayCritical(env, type, NULL);
    uint8_t *input_p = (*env)->GetPrimitiveArrayCritical(env, input, NULL);
    if (!desc_p || !type_p || !input_p) {
        if (input_p) (*env)->ReleasePrimitiveArrayCritical(env, input, input_p, JNI_ABORT);
        if (type_p) (*env)->ReleasePrimitiveArrayCritical(env, type, type_p, JNI_ABORT);
        if (desc_p) (*env)->ReleasePrimitiveArrayCritical(env, desc, desc_p, JNI_ABORT);
        throw_ise(env, "struct codec: array pin failed");
        return NULL;
    }
    int rc = fn(desc_p, (size_t)desc_len, type_p, (size_t)type_len, input_p,
                (size_t)input_len, &out, &out_len, &err);
    (*env)->ReleasePrimitiveArrayCritical(env, input, input_p, JNI_ABORT);
    (*env)->ReleasePrimitiveArrayCritical(env, type, type_p, JNI_ABORT);
    (*env)->ReleasePrimitiveArrayCritical(env, desc, desc_p, JNI_ABORT);
    if (rc != 0) {
        throw_ise(env, err ? err : "struct codec transcode failed");
        if (err && free_error) {
            free_error(err);
        }
        return NULL;
    }
    jbyteArray result = (*env)->NewByteArray(env, (jsize)out_len);
    if (out_len > 0) {
        (*env)->SetByteArrayRegion(env, result, 0, (jsize)out_len,
                                   (const jbyte *)out);
    }
    if (free_bytes) {
        free_bytes(out, out_len);
    }
    return result;
}

JNIEXPORT jbyteArray JNICALL
Java_grpcdc_StructDc_nativeTranscode(JNIEnv *env, jobject self,
                                     jboolean encode, jbyteArray desc,
                                     jbyteArray type, jbyteArray input) {
    (void)self;
    return transcode(env, encode, desc, type, input);
}

/* Scala object StructDc lives on grpcdc.StructDc$ (JNI: _00024). */
JNIEXPORT jbyteArray JNICALL
Java_grpcdc_StructDc_00024_nativeTranscode(JNIEnv *env, jobject self,
                                           jboolean encode, jbyteArray desc,
                                           jbyteArray type, jbyteArray input) {
    (void)self;
    return transcode(env, encode, desc, type, input);
}
