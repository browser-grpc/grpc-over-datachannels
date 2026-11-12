/* JNI shim over libkafka_native for grpcdc.KafkaNative.
 * JDK 17 has no stable FFI, so Java reaches the C ABI
 * through these thin native methods.
 *
 * Build (Linux):
 *   cc -shared -fPIC \
 *     -I$JAVA_HOME/include -I$JAVA_HOME/include/linux \
 *     -Icrates/kafka-native/include \
 *     java/jni/kafka_native_jni.c \
 *     -Lcrates/kafka-native/target/debug -lkafka_native \
 *     -o libkafka_native_jni.so
 *
 * SPDX-License-Identifier: Apache-2.0
 */
#include <jni.h>
#include <stdlib.h>
#include <string.h>

#include "kafka_native.h"

static char *dup_bytes(JNIEnv *env, jbyteArray arr, size_t *out_len) {
    jsize len = (*env)->GetArrayLength(env, arr);
    char *buf = malloc(len > 0 ? (size_t)len : 1);
    if (len > 0) {
        (*env)->GetByteArrayRegion(env, arr, 0, len, (jbyte *)buf);
    }
    *out_len = (size_t)len;
    return buf;
}

static jbyteArray to_java_bytes(JNIEnv *env, uint8_t *ptr, size_t len) {
    jbyteArray out = (*env)->NewByteArray(env, (jsize)len);
    if (len > 0) {
        (*env)->SetByteArrayRegion(env, out, 0, (jsize)len, (const jbyte *)ptr);
    }
    kafka_native_bytes_free(ptr, len);
    return out;
}

static const char *cstr(JNIEnv *env, jstring s, char **owned) {
    *owned = NULL;
    if (s == NULL) {
        return NULL;
    }
    const char *utf = (*env)->GetStringUTFChars(env, s, NULL);
    *owned = (char *)utf;
    return utf;
}

JNIEXPORT jlong JNICALL
Java_grpcdc_KafkaNative_nativeNew(JNIEnv *env, jclass cls, jstring broker, jstring client_id) {
    (void)cls;
    char *b_owned = NULL, *c_owned = NULL;
    const char *b = cstr(env, broker, &b_owned);
    const char *c = cstr(env, client_id, &c_owned);
    KafkaNativeHandle *h = kafka_native_new(b, c);
    if (b_owned) (*env)->ReleaseStringUTFChars(env, broker, b_owned);
    if (c_owned) (*env)->ReleaseStringUTFChars(env, client_id, c_owned);
    return (jlong)(intptr_t)h;
}

JNIEXPORT void JNICALL
Java_grpcdc_KafkaNative_nativeFree(JNIEnv *env, jclass cls, jlong handle) {
    (void)env;
    (void)cls;
    kafka_native_free((KafkaNativeHandle *)(intptr_t)handle);
}

JNIEXPORT jbyteArray JNICALL
Java_grpcdc_KafkaNative_nativeCall(JNIEnv *env, jclass cls, jlong handle,
                                   jstring method, jbyteArray req) {
    (void)cls;
    char *m_owned = NULL;
    const char *m = cstr(env, method, &m_owned);
    size_t req_len = 0;
    char *req_buf = dup_bytes(env, req, &req_len);
    uint8_t *out = NULL;
    size_t out_len = 0;
    int rc = kafka_native_call((KafkaNativeHandle *)(intptr_t)handle, m,
                               (const uint8_t *)req_buf, req_len, &out, &out_len);
    free(req_buf);
    if (m_owned) (*env)->ReleaseStringUTFChars(env, method, m_owned);
    if (rc != 0) {
        return NULL;
    }
    return to_java_bytes(env, out, out_len);
}

JNIEXPORT jlong JNICALL
Java_grpcdc_KafkaNative_nativeStreamNew(JNIEnv *env, jclass cls, jlong handle,
                                        jstring method, jbyteArray req) {
    (void)cls;
    char *m_owned = NULL;
    const char *m = cstr(env, method, &m_owned);
    size_t req_len = 0;
    char *req_buf = dup_bytes(env, req, &req_len);
    KafkaNativeStream *s = kafka_native_stream_new(
        (KafkaNativeHandle *)(intptr_t)handle, m,
        (const uint8_t *)req_buf, req_len);
    free(req_buf);
    if (m_owned) (*env)->ReleaseStringUTFChars(env, method, m_owned);
    return (jlong)(intptr_t)s;
}

/* Stream error state: kafka_native_stream_next reports
 * 1 item / 0 end / -1 error; we stash the distinction by
 * peeking at last_error only after an error return. To keep
 * end-vs-error exact, nativeStreamNext returns NULL for both
 * and nativeStreamError reports (and clears) a shim-side flag
 * set here. */
static __thread int g_stream_failed = 0;
static __thread char g_stream_error[512];

JNIEXPORT jbyteArray JNICALL
Java_grpcdc_KafkaNative_nativeStreamNext(JNIEnv *env, jclass cls, jlong stream) {
    (void)cls;
    uint8_t *out = NULL;
    size_t out_len = 0;
    int rc = kafka_native_stream_next((KafkaNativeStream *)(intptr_t)stream, &out, &out_len);
    if (rc == 1) {
        g_stream_failed = 0;
        return to_java_bytes(env, out, out_len);
    }
    if (rc < 0) {
        const char *err = kafka_native_last_error();
        g_stream_failed = 1;
        snprintf(g_stream_error, sizeof(g_stream_error), "%s",
                 err != NULL ? err : "kafka-native stream error");
    } else {
        g_stream_failed = 0;
    }
    return NULL;
}

JNIEXPORT jstring JNICALL
Java_grpcdc_KafkaNative_nativeStreamError(JNIEnv *env, jclass cls, jlong stream) {
    (void)cls;
    (void)stream;
    if (!g_stream_failed) {
        return NULL;
    }
    g_stream_failed = 0;
    return (*env)->NewStringUTF(env, g_stream_error);
}

JNIEXPORT void JNICALL
Java_grpcdc_KafkaNative_nativeStreamFree(JNIEnv *env, jclass cls, jlong stream) {
    (void)env;
    (void)cls;
    kafka_native_stream_free((KafkaNativeStream *)(intptr_t)stream);
}

JNIEXPORT jstring JNICALL
Java_grpcdc_KafkaNative_nativeLastError(JNIEnv *env, jclass cls) {
    (void)cls;
    const char *err = kafka_native_last_error();
    return (*env)->NewStringUTF(env, err != NULL ? err : "kafka-native error");
}
