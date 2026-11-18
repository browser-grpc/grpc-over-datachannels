/* grpcdc_ice.h — C ABI over the dc-webrtc ICE agent.
 *
 * The agent is sans-io: candidates and credentials cross
 * as data (SDP lines, "ip:port" strings), STUN packets
 * cross as bytes, and checks/responses/events come out as
 * framed buffers. Gathering (interfaces, srflx, TURN,
 * mDNS) stays host-side, exactly like socket I/O for the
 * SCTP core.
 *
 * Packet outputs: repeated [u32 BE len][packet]
 * [u16 BE addr_len][addr "ip:port"].
 * Events: repeated [u8 kind][u16 BE addr_len][addr];
 * kind 1=PairValid, 2=Nominated. Outputs stash in the
 * handle on -2 (re-read with grpcdc_ice_drain).
 *
 * Returns: >=0 bytes/count, -1 null argument, -2 buffer
 * too small, -100 internal panic (contained).
 */
#ifndef GRPCDC_ICE_H
#define GRPCDC_ICE_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct grpcdc_ice grpcdc_ice_t;

grpcdc_ice_t *grpcdc_ice_new(uint8_t controlling);
void grpcdc_ice_free(grpcdc_ice_t *h);
void grpcdc_ice_restart(grpcdc_ice_t *h);

/* Local credentials copy (NUL-terminated); returns the
 * full length of the string. */
int64_t grpcdc_ice_local_ufrag(const grpcdc_ice_t *h, char *buf, size_t cap);
int64_t grpcdc_ice_local_pwd(const grpcdc_ice_t *h, char *buf, size_t cap);

/* Add one local host candidate ("ip:port"). */
int32_t grpcdc_ice_add_local_host(grpcdc_ice_t *h, const char *addr);

/* Remote credentials + one candidate SDP line
 * ("candidate:..." with or without the prefix). */
int32_t grpcdc_ice_set_remote(grpcdc_ice_t *h, const char *ufrag, const char *pwd);
int32_t grpcdc_ice_add_remote_candidate(grpcdc_ice_t *h, const char *sdp_line);

/* Checks that are due now: framed (packet, addr) pairs. */
int64_t grpcdc_ice_due_checks(grpcdc_ice_t *h, uint8_t *out, size_t cap);

/* Feed one STUN datagram from src ("ip:port"): framed
 * responses out, events into out_events (*events_len). */
int64_t grpcdc_ice_handle_stun(grpcdc_ice_t *h,
                               const uint8_t *packet, size_t len,
                               const char *src,
                               uint8_t *out, size_t cap,
                               uint8_t *out_events, size_t events_cap,
                               size_t *events_len);

/* Re-read stashed check/response outputs after -2. */
int64_t grpcdc_ice_drain(grpcdc_ice_t *h, uint8_t *out, size_t cap);

/* Consent: one framed check pair, or 0 when none due. */
int64_t grpcdc_ice_consent_check(grpcdc_ice_t *h, uint8_t *out, size_t cap);
void grpcdc_ice_touch_consent(grpcdc_ice_t *h);
int32_t grpcdc_ice_consent_expired(const grpcdc_ice_t *h, uint64_t expiry_ms);

/* Nominated remote addr copy, or 0 when none. */
int64_t grpcdc_ice_nominated(const grpcdc_ice_t *h, char *buf, size_t cap);

#ifdef __cplusplus
}
#endif

#endif /* GRPCDC_ICE_H */
