/* grpcdc_dtls.h — C ABI over the dc-webrtc DTLS handshake
 * (DtlsHandshake) and established connection (DtlsCore).
 *
 * Sans-io pump: start a handshake, feed datagrams with
 * handle_datagram, call tick at next_timeout, send what
 * comes out. Multi-packet outputs are framed as repeated
 * [u32 big-endian length][packet] in one caller buffer,
 * stashed in the handle on -2 (re-read with drain; the
 * call itself is never re-run).
 *
 * Returns: >=0 bytes written (or value), -1 null argument,
 * -2 buffer too small, -3 no app data (handle_app only),
 * -100 internal panic (contained).
 */
#ifndef GRPCDC_DTLS_H
#define GRPCDC_DTLS_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct grpcdc_dtls grpcdc_dtls_t;
typedef struct grpcdc_dtls_session grpcdc_dtls_session_t;

/* Certificate: X.509 DER + P-256 private scalar (32 bytes,
 * big-endian). expected_fingerprint: nullable
 * "AA:BB:..." string. ticket_key: nullable 32 bytes. */
typedef struct {
    const uint8_t *cert_der;
    size_t cert_der_len;
    const uint8_t *key_scalar;
    const char *expected_fingerprint;
    uint8_t require_peer_certificate;
    uint8_t session_resumption;
    const uint8_t *ticket_key;
    const uint8_t *connection_id;
    size_t connection_id_len;
    const uint8_t *pair_hint;
    size_t pair_hint_len;
} grpcdc_dtls_config;

/* Start a handshake at now_ms (host monotonic clock).
 * new_client returns the first flight via
 * grpcdc_dtls_start; resume may be NULL. */
grpcdc_dtls_t *grpcdc_dtls_new_client(const grpcdc_dtls_config *cfg,
                                      const grpcdc_dtls_session_t *resume,
                                      uint64_t now_ms);
grpcdc_dtls_t *grpcdc_dtls_new_server(const grpcdc_dtls_config *cfg,
                                      uint64_t now_ms);
void grpcdc_dtls_free(grpcdc_dtls_t *h);

/* Initial client flight, framed. */
int64_t grpcdc_dtls_start(grpcdc_dtls_t *h, uint8_t *out, size_t cap);

/* Feed one inbound datagram; framed outbound datagrams. */
int64_t grpcdc_dtls_handle_datagram(grpcdc_dtls_t *h,
                                    const uint8_t *packet, size_t len,
                                    uint64_t now_ms,
                                    uint8_t *out, size_t cap);

/* Timer entry (retransmits, window expiries). */
int64_t grpcdc_dtls_tick(grpcdc_dtls_t *h, uint64_t now_ms,
                         uint8_t *out, size_t cap);

/* Re-read stashed outputs after a -2 with bigger buffers. */
int64_t grpcdc_dtls_drain(grpcdc_dtls_t *h, uint8_t *out, size_t cap);

/* Milliseconds until the next tick, or -1 (done/failed). */
int64_t grpcdc_dtls_next_timeout(const grpcdc_dtls_t *h, uint64_t now_ms);

int32_t grpcdc_dtls_is_established(const grpcdc_dtls_t *h);
int32_t grpcdc_dtls_was_resumed(const grpcdc_dtls_t *h);
/* Failure message copy; returns its length. */
int64_t grpcdc_dtls_failure(const grpcdc_dtls_t *h, char *buf, size_t cap);

/* Established phase: one raw record in `out`. */
int64_t grpcdc_dtls_encrypt_app(grpcdc_dtls_t *h,
                                const uint8_t *data, size_t len,
                                uint8_t *out, size_t cap);
/* Returns payload length, or -3 (no app data in packet). */
int64_t grpcdc_dtls_handle_app(grpcdc_dtls_t *h,
                               const uint8_t *packet, size_t len,
                               uint8_t *out, size_t cap);

/* Peer fingerprint copy (established); returns length. */
int64_t grpcdc_dtls_peer_fingerprint(const grpcdc_dtls_t *h,
                                     char *buf, size_t cap);

/* Captured resumption state (established); take once. */
grpcdc_dtls_session_t *grpcdc_dtls_take_session(grpcdc_dtls_t *h);
void grpcdc_dtls_session_free(grpcdc_dtls_session_t *s);

#ifdef __cplusplus
}
#endif

#endif /* GRPCDC_DTLS_H */
