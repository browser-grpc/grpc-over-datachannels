/* kafka_native: in-process Kafka protocol client (C ABI).
 *
 * Embed the Kafka client in a native application: no proxy
 * process, no gRPC hop. Calls take a grpcdc.kafka.v1 method
 * name ("CreateTopics", "Produce", "Consume", ...) and the
 * protobuf-encoded request, and return the protobuf-encoded
 * response — the exact bytes the gRPC service exchanges.
 *
 * SASL (PLAIN/SCRAM) and TLS are available through
 * kafka_native_new_v2.
 *
 * SPDX-License-Identifier: Apache-2.0
 */
#ifndef GRPC_DC_KAFKA_NATIVE_H
#define GRPC_DC_KAFKA_NATIVE_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct KafkaNativeHandle KafkaNativeHandle;
typedef struct KafkaNativeStream KafkaNativeStream;

/* New client for broker "host:port". NULL on error
 * (see kafka_native_last_error). client_id may be NULL. */
KafkaNativeHandle *kafka_native_new(const char *broker,
                                    const char *client_id);

/* Full configuration. All strings may be NULL.
 * sasl_mechanism: NULL, "PLAIN", "SCRAM-SHA-256", or
 * "SCRAM-SHA-512" (username/password required then).
 * TLS is enabled when tls_ca_cert (PEM file path) is set
 * or tls_insecure_skip_verify is nonzero. */
typedef struct KafkaNativeConfig {
    const char *broker;
    const char *client_id;
    const char *sasl_mechanism;
    const char *username;
    const char *password;
    const char *tls_ca_cert;
    const char *tls_server_name;
    int tls_insecure_skip_verify;
} KafkaNativeConfig;

KafkaNativeHandle *kafka_native_new_v2(const KafkaNativeConfig *cfg);
void kafka_native_free(KafkaNativeHandle *handle);

/* Unary call. Returns 0 on success; *out/*out_len receive a
 * buffer to free with kafka_native_bytes_free. -1 on error. */
int kafka_native_call(KafkaNativeHandle *handle,
                      const char *method,
                      const uint8_t *req, size_t req_len,
                      uint8_t **out, size_t *out_len);

/* Server-streaming call ("Consume" / "Subscribe"). NULL on
 * error. */
KafkaNativeStream *kafka_native_stream_new(KafkaNativeHandle *handle,
                                           const char *method,
                                           const uint8_t *req,
                                           size_t req_len);
/* 1 = item in *out, 0 = stream ended, -1 = error. */
int kafka_native_stream_next(KafkaNativeStream *stream,
                             uint8_t **out, size_t *out_len);
void kafka_native_stream_free(KafkaNativeStream *stream);

void kafka_native_bytes_free(uint8_t *ptr, size_t len);

/* Last error text for this thread (valid until the next
 * FFI call on the same thread). */
const char *kafka_native_last_error(void);

#ifdef __cplusplus
}
#endif

#endif /* GRPC_DC_KAFKA_NATIVE_H */
