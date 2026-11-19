/* grpcdc_sctp.h — C ABI over the dc-webrtc SCTP association.
 *
 * The association is a sans-io state machine: the host pumps
 * datagrams in (handle_packet) and sends what comes out.
 * All multi-packet outputs use one caller buffer of repeated
 * [u32 big-endian length][packet] records.
 *
 * Return convention for buffer-writing calls:
 *   >= 0  bytes written
 *   -1    null handle/argument
 *   -2    buffer too small (nothing written; call again bigger)
 *   -100  internal panic (contained at the boundary)
 *
 * Events buffer (handle_packet/tick out_events): repeated
 *   [u8 kind][u16 BE stream][u32 BE ppid][u32 BE len][payload]
 * kind: 1=Connected 2=Data 3=StreamReset 4=Closed.
 * Pointers into event payloads are not returned; the buffer
 * is self-contained.
 */
#ifndef GRPCDC_SCTP_H
#define GRPCDC_SCTP_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct grpcdc_sctp grpcdc_sctp_t;

grpcdc_sctp_t *grpcdc_sctp_new_client(uint16_t local_port, uint16_t peer_port);
grpcdc_sctp_t *grpcdc_sctp_new_server(uint16_t local_port, uint16_t peer_port);
void grpcdc_sctp_free(grpcdc_sctp_t *h);
int32_t grpcdc_sctp_is_established(const grpcdc_sctp_t *h);

/* INIT packet into out[0..cap); returns its length. */
int64_t grpcdc_sctp_connect(grpcdc_sctp_t *h, uint64_t now_ms,
                            uint8_t *out, size_t cap);

/* max_retransmits / max_lifetime_ms: -1 = unset (reliable). */
int64_t grpcdc_sctp_send_data(grpcdc_sctp_t *h, uint16_t stream, uint32_t ppid,
                              const uint8_t *data, size_t len,
                              uint8_t unordered, int32_t max_retransmits,
                              int64_t max_lifetime_ms, uint64_t now_ms,
                              uint8_t *out, size_t cap);

/* On success *events_len receives the events bytes written
 * (the packets byte count is the return value). On -2 the
 * call HAS run (state advanced) and its outputs are stashed
 * in the handle: grow the buffers and re-read them with
 * grpcdc_sctp_drain — never re-run the same packet. */
int64_t grpcdc_sctp_handle_packet(grpcdc_sctp_t *h,
                                  const uint8_t *packet, size_t len,
                                  uint64_t now_ms,
                                  uint8_t *out_packets, size_t packets_cap,
                                  uint8_t *out_events, size_t events_cap,
                                  size_t *events_len);

int64_t grpcdc_sctp_tick(grpcdc_sctp_t *h, uint64_t now_ms,
                         uint8_t *out_packets, size_t packets_cap,
                         uint8_t *out_events, size_t events_cap,
                         size_t *events_len);

/* Re-read the stashed outputs of the last handle_packet
 * or tick call (after a -2 return with bigger buffers).
 * Never re-runs the core; safe to call repeatedly. */
int64_t grpcdc_sctp_drain(grpcdc_sctp_t *h,
                          uint8_t *out_packets, size_t packets_cap,
                          uint8_t *out_events, size_t events_cap,
                          size_t *events_len);

/* Writes 7 counters: packets_sent, packets_received,
 * chunks_sent, chunks_received, retransmits,
 * fast_retransmits, dup_chunks. */
int32_t grpcdc_sctp_stats(const grpcdc_sctp_t *h, uint64_t *out7);

int64_t grpcdc_sctp_close_stream(grpcdc_sctp_t *h, uint16_t stream,
                                 uint8_t *out, size_t cap);
int64_t grpcdc_sctp_close(grpcdc_sctp_t *h, uint64_t now_ms,
                          uint8_t *out, size_t cap);

#ifdef __cplusplus
}
#endif

#endif /* GRPCDC_SCTP_H */
