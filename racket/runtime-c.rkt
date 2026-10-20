#lang racket

;;; runtime-c.rkt — the C99 gRPC runtime, emitted by metagen.rkt.
;;;
;;; The runtime files under c/grpcdc/ are GENERATED from the bodies
;;; below, with frame/status constants stamped from spec.rkt's
;;; tables. Do not edit the generated runtime files; edit here and
;;; run `make generate`.
;;;
;;; C99 stdlib only — no external packages. Statuses are values
;;; (grpcdc_status), streaming is via explicit stream handles, and
;;; the transport is a two-function vtable (send/recv one whole
;;; DataChannel message). The blocking, single-threaded call model
;;; targets embedded-style poll loops: generated clients drive one
;;; stream at a time.

(require "spec.rkt")
(provide emit-c-runtime-files)

(define (stamp-frame-consts)
  (apply string-append
         (map (lambda (e)
                (format "#define GRPCDC_FRAME_~a ~a\n"
                        (string-replace (symbol->string (first e)) "-" "_")
                        (number->string (second e) 16)))
              frame-table)))

(define (stamp-status-consts)
  (apply string-append
         (map (lambda (e)
                (format "#define GRPCDC_~a ~a\n"
                        (string-replace (symbol->string (first e)) "-" "_")
                        (second e)))
              status-table)))

(define (stamp-status-names)
  (string-append
   "const char *grpcdc_status_name(int code) {\n    switch (code) {\n"
   (apply string-append
          (map (lambda (e)
                 (format "        case GRPCDC_~a: return ~s;\n"
                         (string-replace (symbol->string (first e)) "-" "_")
                         (symbol->string (first e))))
               status-table))
   "        default: return \"UNKNOWN\";\n    }\n}\n"))

(define c-header-body
#<<GRPC_RUNTIME_EOF
#ifndef GRPCDC_GRPCDC_H
#define GRPCDC_GRPCDC_H

#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Frame types and status codes, stamped from racket/spec.rkt. */
@@FRAME_CONSTS@@
@@STATUS_CONSTS@@

/* A gRPC status carried as a value (C has no exceptions). */
typedef struct {
    int code;
    char message[256];
} grpcdc_status;

const char *grpcdc_status_name(int code);
grpcdc_status grpcdc_status_make(int code, const char *message);
grpcdc_status grpcdc_ok(void);
bool grpcdc_status_is_ok(grpcdc_status st);

/* ---- homegrown tracing (W3C traceparent propagation) ----
   Dormant until grpcdc_set_tracer registers an observer.
   Dependency-free: sampling/export are the app's problem. */
typedef struct {
    void *ctx;
    void (*on_start)(void *ctx, const char *kind, const char *method,
                     const char *trace_id, const char *span_id,
                     const char *parent_span_id);
    void (*on_end)(void *ctx, const char *kind, const char *method,
                   const char *trace_id, const char *span_id,
                   const char *status);
} grpcdc_tracer;

void grpcdc_set_tracer(const grpcdc_tracer *tracer);
bool grpcdc_tracing_enabled(void);

/* Restrict traced methods: ';'-separated paths, a trailing '*'
   means prefix match ('/echo.Echo/*'). Empty/NULL = trace all. */
void grpcdc_set_trace_filter(const char *patterns);

typedef struct {
    char trace_id[33];
    char span_id[17];
    char parent_span_id[17];
    int active;
} grpcdc_trace_context;

/* Begin a span; parent_traceparent may be NULL. The returned
   context has active=0 when tracing is dormant. */
grpcdc_trace_context grpcdc_trace_start(const char *kind, const char *method,
                                        const char *parent_traceparent);
void grpcdc_trace_end(const char *kind, const char *method,
                      const grpcdc_trace_context *ctx, const char *status);
/* Format "00-<trace>-<span>-01" into out[56]; returns out. */
char *grpcdc_format_traceparent(const grpcdc_trace_context *ctx, char *out);

/* Owned byte buffer (malloc'd; free data or use grpcdc_bytes_free). */
typedef struct {
    uint8_t *data;
    size_t len;
} grpcdc_bytes;

void grpcdc_bytes_free(grpcdc_bytes *b);

/* One metadata key/value pair. */
typedef struct {
    const char *key;
    const char *value;
} grpcdc_kv;

/* Transport: moves whole DataChannel messages. send returns 0 on
   success. recv returns 0 and a malloc'd message, or -1 when the
   transport is closed. */
typedef struct grpcdc_transport {
    void *ctx;
    int (*send)(void *ctx, const uint8_t *data, size_t len);
    int (*recv)(void *ctx, uint8_t **out, size_t *len);
    /* Optional: like recv, but returns -2 when abs_deadline_ms
       (CLOCK_MONOTONIC milliseconds) passes with no message.
       NULL means deadlines are only checked between messages. */
    int (*recv_until)(void *ctx, uint8_t **out, size_t *len,
                      int64_t abs_deadline_ms);
} grpcdc_transport;

/* Current CLOCK_MONOTONIC time in milliseconds. */
int64_t grpcdc_now_ms(void);

/* ---- wire codec (SPEC.md) ---- */
#define GRPCDC_HEADER_LEN 9
#define GRPCDC_MAX_DATA_PAYLOAD (16u * 1024u * 1024u)

typedef struct {
    uint8_t type;
    uint32_t stream_id;
    const uint8_t *payload;
    size_t payload_len;
} grpcdc_frame;

grpcdc_status grpcdc_encode_frame(uint8_t type, uint32_t stream_id,
                                  const uint8_t *payload, size_t len,
                                  grpcdc_bytes *out);
grpcdc_status grpcdc_decode_frame(const uint8_t *data, size_t len,
                                  grpcdc_frame *out);
grpcdc_status grpcdc_encode_data_message(const uint8_t *msg, size_t len,
                                         grpcdc_bytes *out);
/* Decode one framed message from a DATA payload; *offset advances. */
grpcdc_status grpcdc_decode_data_message(const uint8_t *payload, size_t len,
                                         size_t *offset, grpcdc_bytes *out);
char *grpcdc_encode_timeout(int64_t timeout_ms);
bool grpcdc_parse_timeout(const char *text, int64_t *out_ms);
grpcdc_status grpcdc_headers_frame(uint32_t stream_id, const char *path,
                                   const grpcdc_kv *md, size_t md_count,
                                   grpcdc_bytes *out);
grpcdc_status grpcdc_status_frame(uint8_t type, uint32_t stream_id,
                                  grpcdc_status status, grpcdc_bytes *out);

typedef struct {
    char *path; /* NULL for response headers */
    grpcdc_kv *metadata;
    size_t metadata_count;
} grpcdc_headers;

grpcdc_status grpcdc_parse_headers(const uint8_t *payload, size_t len,
                                   grpcdc_headers *out);
void grpcdc_headers_free(grpcdc_headers *h);
const char *grpcdc_headers_get(const grpcdc_headers *h, const char *key);
grpcdc_status grpcdc_parse_status_payload(const uint8_t *payload, size_t len);

/* ---- client ---- */
typedef struct grpcdc_channel {
    grpcdc_transport *transport;
    uint32_t next_stream_id;
} grpcdc_channel;

void grpcdc_channel_init(grpcdc_channel *ch, grpcdc_transport *transport);

typedef struct grpcdc_stream grpcdc_stream;

/* Unary call: req is one serialized message; *resp_out receives the
   response message bytes (owned). */
grpcdc_status grpcdc_channel_unary(grpcdc_channel *ch, const char *path,
                                   const uint8_t *req, size_t req_len,
                                   const grpcdc_kv *md, size_t md_count,
                                   int64_t deadline_ms,
                                   grpcdc_bytes *resp_out);

/* Open a stream. When send_first is true, req holds the first (and
   for server-streaming the only) request message, sent with a
   HALF-CLOSE. */
grpcdc_status grpcdc_channel_open(grpcdc_channel *ch, const char *path,
                                  const uint8_t *req, size_t req_len,
                                  int send_first,
                                  const grpcdc_kv *md, size_t md_count,
                                  int64_t deadline_ms,
                                  grpcdc_stream **out);
grpcdc_status grpcdc_stream_send(grpcdc_stream *s, const uint8_t *msg,
                                 size_t len);
grpcdc_status grpcdc_stream_close_send(grpcdc_stream *s);
/* 1 = message in *out, 0 = clean end, -1 = *st holds the status. */
int grpcdc_stream_recv(grpcdc_stream *s, grpcdc_bytes *out,
                       grpcdc_status *st);
void grpcdc_stream_free(grpcdc_stream *s);

/* ---- server ---- */
typedef struct grpcdc_server_stream grpcdc_server_stream;
grpcdc_status grpcdc_server_stream_send(grpcdc_server_stream *s,
                                        const uint8_t *msg, size_t len);
int grpcdc_server_stream_recv(grpcdc_server_stream *s, grpcdc_bytes *out,
                              grpcdc_status *st);

typedef grpcdc_status (*grpcdc_unary_fn)(void *impl, const grpcdc_kv *md,
                                         size_t md_count, grpcdc_bytes req,
                                         grpcdc_bytes *resp);
typedef grpcdc_status (*grpcdc_server_stream_fn)(void *impl,
                                                 const grpcdc_kv *md,
                                                 size_t md_count,
                                                 grpcdc_bytes req,
                                                 grpcdc_server_stream *s);
typedef grpcdc_status (*grpcdc_client_stream_fn)(void *impl,
                                                 grpcdc_server_stream *s,
                                                 grpcdc_bytes *resp);
typedef grpcdc_status (*grpcdc_bidi_fn)(void *impl, grpcdc_server_stream *s);

/* Request metadata of the stream being served. */
void grpcdc_server_stream_metadata(grpcdc_server_stream *s,
                                   const grpcdc_kv **md, size_t *md_count);

/* kind: 0 unary, 1 server-streaming, 2 client-streaming, 3 bidi. */
typedef struct {
    const char *name;
    int kind;
    grpcdc_unary_fn unary;
    grpcdc_server_stream_fn server_stream;
    grpcdc_client_stream_fn client_stream;
    grpcdc_bidi_fn bidi;
} grpcdc_method_desc;

typedef struct grpcdc_server grpcdc_server;
grpcdc_server *grpcdc_server_new(void);
void grpcdc_server_add_service(grpcdc_server *srv, const char *full_name,
                               const grpcdc_method_desc *methods,
                               size_t method_count, void *impl);
/* Serve until the transport closes; returns the close status. */
grpcdc_status grpcdc_server_serve(grpcdc_server *srv,
                                  grpcdc_transport *transport);
void grpcdc_server_free(grpcdc_server *srv);

#ifdef __cplusplus
}
#endif

#endif /* GRPCDC_GRPCDC_H */
GRPC_RUNTIME_EOF
)

(define c-impl-body
#<<GRPC_RUNTIME_EOF
#include "grpcdc.h"

#include <stdio.h>
#include <time.h>

int64_t grpcdc_now_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (int64_t)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}

@@STATUS_NAMES@@

grpcdc_status grpcdc_status_make(int code, const char *message) {
    grpcdc_status st;
    st.code = code;
    if (message) {
        strncpy(st.message, message, sizeof(st.message) - 1);
        st.message[sizeof(st.message) - 1] = 0;
    } else {
        st.message[0] = 0;
    }
    return st;
}

grpcdc_status grpcdc_ok(void) { return grpcdc_status_make(GRPCDC_OK, ""); }
bool grpcdc_status_is_ok(grpcdc_status st) { return st.code == GRPCDC_OK; }

void grpcdc_bytes_free(grpcdc_bytes *b) {
    if (b) {
        free(b->data);
        b->data = NULL;
        b->len = 0;
    }
}

/* ---- homegrown tracing implementation ---- */
static grpcdc_tracer g_tracer;
static int g_tracer_set = 0;

void grpcdc_set_tracer(const grpcdc_tracer *tracer) {
    if (tracer) {
        g_tracer = *tracer;
        g_tracer_set = 1;
    } else {
        g_tracer_set = 0;
    }
}

bool grpcdc_tracing_enabled(void) { return g_tracer_set != 0; }

static char g_trace_filter[512];

void grpcdc_set_trace_filter(const char *patterns) {
    if (!patterns) patterns = "";
    size_t n = strlen(patterns);
    if (n >= sizeof(g_trace_filter)) n = sizeof(g_trace_filter) - 1;
    memcpy(g_trace_filter, patterns, n);
    g_trace_filter[n] = 0;
}

static int trace_allowed(const char *method) {
    if (g_trace_filter[0] == 0) return 1;
    size_t mlen = strlen(method);
    const char *p = g_trace_filter;
    while (*p) {
        const char *semi = strchr(p, ';');
        size_t plen = semi ? (size_t)(semi - p) : strlen(p);
        if (plen > 0) {
            if (p[plen - 1] == '*') {
                if (mlen >= plen - 1 && strncmp(method, p, plen - 1) == 0) return 1;
            } else if (mlen == plen && strncmp(method, p, plen) == 0) {
                return 1;
            }
        }
        if (!semi) break;
        p = semi + 1;
    }
    return 0;
}

static uint64_t trace_rng_state = 0;

static void trace_random_hex(char *out, size_t nbytes) {
    static const char digits[] = "0123456789abcdef";
    if (trace_rng_state == 0) {
        trace_rng_state = (uint64_t)grpcdc_now_ms() * 2685821657736338717ull
                          ^ 0x9e3779b97f4a7c15ull;
    }
    for (size_t i = 0; i < nbytes; i++) {
        uint64_t x = trace_rng_state;
        x ^= x << 13;
        x ^= x >> 7;
        x ^= x << 17;
        trace_rng_state = x;
        unsigned int b = (unsigned int)(x >> 32) & 0xffu;
        out[i * 2] = digits[b >> 4];
        out[i * 2 + 1] = digits[b & 0xfu];
    }
    out[nbytes * 2] = 0;
}

static int trace_is_hex(const char *s, size_t len) {
    for (size_t i = 0; i < len; i++) {
        char c = s[i];
        if (!((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f'))) return 0;
    }
    return 1;
}

grpcdc_trace_context grpcdc_trace_start(const char *kind, const char *method,
                                        const char *parent_traceparent) {
    grpcdc_trace_context ctx;
    memset(&ctx, 0, sizeof(ctx));
    if (!g_tracer_set || !g_tracer.on_start || !trace_allowed(method)) return ctx;
    if (parent_traceparent) {
        /* 00-<32>-<16>-01 */
        const char *p = parent_traceparent;
        if (strlen(p) == 55 && p[2] == '-' && p[35] == '-' && p[52] == '-'
            && trace_is_hex(p + 3, 32) && trace_is_hex(p + 36, 16)) {
            memcpy(ctx.trace_id, p + 3, 32);
            memcpy(ctx.parent_span_id, p + 36, 16);
        }
    }
    if (ctx.trace_id[0] == 0) trace_random_hex(ctx.trace_id, 16);
    trace_random_hex(ctx.span_id, 8);
    ctx.active = 1;
    g_tracer.on_start(g_tracer.ctx, kind, method, ctx.trace_id, ctx.span_id,
                      ctx.parent_span_id);
    return ctx;
}

void grpcdc_trace_end(const char *kind, const char *method,
                      const grpcdc_trace_context *ctx, const char *status) {
    if (!ctx || !ctx->active || !g_tracer_set || !g_tracer.on_end) return;
    g_tracer.on_end(g_tracer.ctx, kind, method, ctx->trace_id, ctx->span_id,
                    status);
}

char *grpcdc_format_traceparent(const grpcdc_trace_context *ctx, char *out) {
    memcpy(out, "00-", 3);
    memcpy(out + 3, ctx->trace_id, 32);
    out[35] = '-';
    memcpy(out + 36, ctx->span_id, 16);
    memcpy(out + 52, "-01", 4);
    return out;
}

static void put_u32(uint8_t *out, size_t off, uint32_t v) {
    out[off] = (uint8_t)((v >> 24) & 0xff);
    out[off + 1] = (uint8_t)((v >> 16) & 0xff);
    out[off + 2] = (uint8_t)((v >> 8) & 0xff);
    out[off + 3] = (uint8_t)(v & 0xff);
}

static uint32_t get_u32(const uint8_t *in, size_t off) {
    return ((uint32_t)in[off] << 24) | ((uint32_t)in[off + 1] << 16) |
           ((uint32_t)in[off + 2] << 8) | (uint32_t)in[off + 3];
}

static bool valid_frame_type(uint8_t t) {
    return t == GRPCDC_FRAME_HEADERS || t == GRPCDC_FRAME_DATA ||
           t == GRPCDC_FRAME_TRAILERS || t == GRPCDC_FRAME_HALF_CLOSE ||
           t == GRPCDC_FRAME_RST;
}

grpcdc_status grpcdc_encode_frame(uint8_t type, uint32_t stream_id,
                                  const uint8_t *payload, size_t len,
                                  grpcdc_bytes *out) {
    if (!valid_frame_type(type))
        return grpcdc_status_make(GRPCDC_INVALID_ARGUMENT, "unknown frame type");
    if (type == GRPCDC_FRAME_DATA && len > GRPCDC_MAX_DATA_PAYLOAD)
        return grpcdc_status_make(GRPCDC_RESOURCE_EXHAUSTED,
                                  "DATA payload exceeds 16 MiB");
    out->data = (uint8_t *)malloc(GRPCDC_HEADER_LEN + len);
    if (!out->data)
        return grpcdc_status_make(GRPCDC_RESOURCE_EXHAUSTED, "out of memory");
    out->len = GRPCDC_HEADER_LEN + len;
    out->data[0] = type;
    put_u32(out->data, 1, stream_id);
    put_u32(out->data, 5, (uint32_t)len);
    if (len) memcpy(out->data + GRPCDC_HEADER_LEN, payload, len);
    return grpcdc_ok();
}

grpcdc_status grpcdc_decode_frame(const uint8_t *data, size_t len,
                                  grpcdc_frame *out) {
    if (len < GRPCDC_HEADER_LEN)
        return grpcdc_status_make(GRPCDC_INVALID_ARGUMENT,
                                  "frame shorter than 9-byte header");
    uint32_t plen = get_u32(data, 5);
    if (plen != len - GRPCDC_HEADER_LEN)
        return grpcdc_status_make(GRPCDC_INVALID_ARGUMENT,
                                  "payload length does not match message size");
    out->type = data[0];
    out->stream_id = get_u32(data, 1);
    out->payload = data + GRPCDC_HEADER_LEN;
    out->payload_len = plen;
    return grpcdc_ok();
}

/* On the DataChannel wire a DATA payload is exactly one raw
   serialized message (SPEC.md) — no gRPC length framing. These
   helpers copy the message in and out. */
grpcdc_status grpcdc_encode_data_message(const uint8_t *msg, size_t len,
                                         grpcdc_bytes *out) {
    out->data = (uint8_t *)malloc(len ? len : 1);
    if (!out->data)
        return grpcdc_status_make(GRPCDC_RESOURCE_EXHAUSTED, "out of memory");
    out->len = len;
    if (len) memcpy(out->data, msg, len);
    return grpcdc_ok();
}

grpcdc_status grpcdc_decode_data_message(const uint8_t *payload, size_t len,
                                         size_t *offset, grpcdc_bytes *out) {
    if (*offset > len)
        return grpcdc_status_make(GRPCDC_INVALID_ARGUMENT,
                                  "bad data offset");
    size_t n = len - *offset;
    out->data = (uint8_t *)malloc(n ? n : 1);
    if (!out->data)
        return grpcdc_status_make(GRPCDC_RESOURCE_EXHAUSTED, "out of memory");
    out->len = n;
    if (n) memcpy(out->data, payload + *offset, n);
    *offset = len;
    return grpcdc_ok();
}

/* ---- timeout grammar ---- */
char *grpcdc_encode_timeout(int64_t timeout_ms) {
    char buf[32];
    if (timeout_ms <= 99999999)
        snprintf(buf, sizeof(buf), "%lld" "m", (long long)timeout_ms);
    else
        snprintf(buf, sizeof(buf), "%lld" "S",
                 (long long)((timeout_ms + 999) / 1000));
    size_t n = strlen(buf);
    char *out = (char *)malloc(n + 1);
    memcpy(out, buf, n + 1);
    return out;
}

bool grpcdc_parse_timeout(const char *text, int64_t *out_ms) {
    size_t len = strlen(text);
    if (len < 2 || len > 9) return false;
    int64_t n = 0;
    for (size_t i = 0; i + 1 < len; i++) {
        if (text[i] < '0' || text[i] > '9') return false;
        n = n * 10 + (text[i] - '0');
    }
    switch (text[len - 1]) {
        case 'H': *out_ms = n * 3600000; return true;
        case 'M': *out_ms = n * 60000; return true;
        case 'S': *out_ms = n * 1000; return true;
        case 'm': *out_ms = n; return true;
        case 'u': *out_ms = (n + 999) / 1000; return true;
        case 'n': *out_ms = (n + 999999) / 1000000; return true;
        default: return false;
    }
}

/* ---- minimal JSON write/parse for HEADERS/TRAILERS payloads ---- */
typedef struct {
    char *buf;
    size_t len;
    size_t cap;
} json_buf;

static void json_put(json_buf *b, const char *s, size_t n) {
    if (b->len + n + 1 > b->cap) {
        size_t cap = b->cap ? b->cap * 2 : 128;
        while (cap < b->len + n + 1) cap *= 2;
        b->buf = (char *)realloc(b->buf, cap);
        b->cap = cap;
    }
    memcpy(b->buf + b->len, s, n);
    b->len += n;
    b->buf[b->len] = 0;
}

static void json_puts(json_buf *b, const char *s) { json_put(b, s, strlen(s)); }

static void json_write_string(json_buf *b, const char *s) {
    json_puts(b, "\"");
    for (const char *p = s; *p; p++) {
        unsigned char c = (unsigned char)*p;
        switch (c) {
            case '"': json_puts(b, "\\\""); break;
            case '\\': json_puts(b, "\\\\"); break;
            case '\n': json_puts(b, "\\n"); break;
            case '\r': json_puts(b, "\\r"); break;
            case '\t': json_puts(b, "\\t"); break;
            default:
                if (c < 0x20) {
                    char tmp[8];
                    snprintf(tmp, sizeof(tmp), "\\u%04x", c);
                    json_puts(b, tmp);
                } else {
                    json_put(b, (const char *)p, 1);
                }
        }
    }
    json_puts(b, "\"");
}

grpcdc_status grpcdc_headers_frame(uint32_t stream_id, const char *path,
                                   const grpcdc_kv *md, size_t md_count,
                                   grpcdc_bytes *out) {
    json_buf b = {0};
    json_puts(&b, "{");
    bool wrote = false;
    if (path) {
        json_puts(&b, "\"path\":");
        json_write_string(&b, path);
        wrote = true;
    }
    if (md && md_count > 0) {
        if (wrote) json_puts(&b, ",");
        json_puts(&b, "\"metadata\":{");
        for (size_t i = 0; i < md_count; i++) {
            if (i) json_puts(&b, ",");
            json_write_string(&b, md[i].key);
            json_puts(&b, ":");
            json_write_string(&b, md[i].value);
        }
        json_puts(&b, "}");
    }
    json_puts(&b, "}");
    grpcdc_status st = grpcdc_encode_frame(GRPCDC_FRAME_HEADERS, stream_id,
                                           (const uint8_t *)b.buf, b.len, out);
    free(b.buf);
    return st;
}

grpcdc_status grpcdc_status_frame(uint8_t type, uint32_t stream_id,
                                  grpcdc_status status, grpcdc_bytes *out) {
    json_buf b = {0};
    char tmp[32];
    snprintf(tmp, sizeof(tmp), "{\"code\":%d,\"message\":", status.code);
    json_puts(&b, tmp);
    json_write_string(&b, status.message);
    json_puts(&b, "}");
    grpcdc_status st =
        grpcdc_encode_frame(type, stream_id, (const uint8_t *)b.buf, b.len, out);
    free(b.buf);
    return st;
}

/* Skip a JSON value starting at *p (p inside a NUL-terminated copy). */
static const char *json_skip(const char *p);
static const char *json_skip_ws(const char *p) {
    while (*p == ' ' || *p == '\t' || *p == '\n' || *p == '\r') p++;
    return p;
}

static const char *json_parse_string(const char *p, char **out) {
    p = json_skip_ws(p);
    if (*p != '"') return NULL;
    p++;
    json_buf b = {0};
    while (*p && *p != '"') {
        if (*p == '\\' && p[1]) {
            p++;
            switch (*p) {
                case 'n': json_put(&b, "\n", 1); break;
                case 't': json_put(&b, "\t", 1); break;
                case 'r': json_put(&b, "\r", 1); break;
                case 'b': json_put(&b, "\b", 1); break;
                case 'f': json_put(&b, "\f", 1); break;
                case '/': json_put(&b, "/", 1); break;
                case '\\': json_put(&b, "\\", 1); break;
                case '"': json_put(&b, "\"", 1); break;
                case 'u': {
                    unsigned cp = 0;
                    for (int i = 0; i < 4 && p[1 + i]; i++) {
                        char c = p[1 + i];
                        cp <<= 4;
                        if (c >= '0' && c <= '9') cp |= (unsigned)(c - '0');
                        else if (c >= 'a' && c <= 'f') cp |= (unsigned)(c - 'a' + 10);
                        else if (c >= 'A' && c <= 'F') cp |= (unsigned)(c - 'A' + 10);
                    }
                    p += 4;
                    if (cp < 0x80) {
                        char c1 = (char)cp;
                        json_put(&b, &c1, 1);
                    } else if (cp < 0x800) {
                        char c2[2] = {(char)(0xc0 | (cp >> 6)),
                                      (char)(0x80 | (cp & 0x3f))};
                        json_put(&b, c2, 2);
                    } else {
                        char c3[3] = {(char)(0xe0 | (cp >> 12)),
                                      (char)(0x80 | ((cp >> 6) & 0x3f)),
                                      (char)(0x80 | (cp & 0x3f))};
                        json_put(&b, c3, 3);
                    }
                    break;
                }
                default: json_put(&b, p, 1); break;
            }
            p++;
        } else {
            json_put(&b, p, 1);
            p++;
        }
    }
    if (*p != '"') {
        free(b.buf);
        return NULL;
    }
    if (!b.buf) {
        b.buf = (char *)malloc(1);
        b.buf[0] = 0;
    }
    *out = b.buf;
    return p + 1;
}

static const char *json_skip(const char *p) {
    p = json_skip_ws(p);
    if (*p == '"') {
        char *tmp = NULL;
        const char *r = json_parse_string(p, &tmp);
        free(tmp);
        return r;
    }
    if (*p == '{' || *p == '[') {
        char open = *p;
        char close = (open == '{') ? '}' : ']';
        int depth = 0;
        while (*p) {
            if (*p == '"') {
                p = json_skip(p);
                if (!p) return NULL;
                continue;
            }
            if (*p == open) depth++;
            if (*p == close) {
                depth--;
                if (depth == 0) return p + 1;
            }
            p++;
        }
        return NULL;
    }
    while (*p && *p != ',' && *p != '}' && *p != ']' && *p != ' ' &&
           *p != '\t' && *p != '\n' && *p != '\r')
        p++;
    return p;
}

static char *dup_range(const uint8_t *payload, size_t len) {
    char *s = (char *)malloc(len + 1);
    memcpy(s, payload, len);
    s[len] = 0;
    return s;
}

grpcdc_status grpcdc_parse_headers(const uint8_t *payload, size_t len,
                                   grpcdc_headers *out) {
    memset(out, 0, sizeof(*out));
    char *text = dup_range(payload, len);
    const char *p = json_skip_ws(text);
    if (*p != '{') {
        free(text);
        return grpcdc_status_make(GRPCDC_INVALID_ARGUMENT,
                                  "bad HEADERS payload");
    }
    p++;
    p = json_skip_ws(p);
    while (*p && *p != '}') {
        char *key = NULL;
        p = json_parse_string(p, &key);
        if (!p) {
            free(text);
            return grpcdc_status_make(GRPCDC_INVALID_ARGUMENT,
                                      "bad HEADERS payload");
        }
        p = json_skip_ws(p);
        if (*p == ':') p++;
        p = json_skip_ws(p);
        if (strcmp(key, "path") == 0) {
            char *val = NULL;
            p = json_parse_string(p, &val);
            if (!p) {
                free(key);
                free(text);
                return grpcdc_status_make(GRPCDC_INVALID_ARGUMENT,
                                          "bad HEADERS payload");
            }
            out->path = val;
        } else if (strcmp(key, "metadata") == 0 && *p == '{') {
            p++;
            p = json_skip_ws(p);
            while (*p && *p != '}') {
                char *mk = NULL;
                p = json_parse_string(p, &mk);
                if (!p) break;
                p = json_skip_ws(p);
                if (*p == ':') p++;
                p = json_skip_ws(p);
                char *mv = NULL;
                if (*p == '"') {
                    p = json_parse_string(p, &mv);
                } else {
                    mv = (char *)malloc(1);
                    mv[0] = 0;
                    p = json_skip(p);
                }
                if (!p) {
                    free(mk);
                    free(mv);
                    break;
                }
                out->metadata = (grpcdc_kv *)realloc(
                    out->metadata, sizeof(grpcdc_kv) * (out->metadata_count + 1));
                out->metadata[out->metadata_count].key = mk;
                out->metadata[out->metadata_count].value = mv;
                out->metadata_count++;
                p = json_skip_ws(p);
                if (*p == ',') p++;
                p = json_skip_ws(p);
            }
            if (*p == '}') p++;
        } else {
            p = json_skip(p);
            if (!p) {
                free(key);
                free(text);
                return grpcdc_status_make(GRPCDC_INVALID_ARGUMENT,
                                          "bad HEADERS payload");
            }
        }
        free(key);
        p = json_skip_ws(p);
        if (*p == ',') p++;
        p = json_skip_ws(p);
    }
    free(text);
    return grpcdc_ok();
}

void grpcdc_headers_free(grpcdc_headers *h) {
    free(h->path);
    for (size_t i = 0; i < h->metadata_count; i++) {
        free((void *)h->metadata[i].key);
        free((void *)h->metadata[i].value);
    }
    free(h->metadata);
    memset(h, 0, sizeof(*h));
}

const char *grpcdc_headers_get(const grpcdc_headers *h, const char *key) {
    for (size_t i = 0; i < h->metadata_count; i++)
        if (strcmp(h->metadata[i].key, key) == 0) return h->metadata[i].value;
    return NULL;
}

grpcdc_status grpcdc_parse_status_payload(const uint8_t *payload, size_t len) {
    char *text = dup_range(payload, len);
    const char *p = json_skip_ws(text);
    int code = GRPCDC_UNKNOWN;
    char msgbuf[256] = "";
    if (*p == '{') {
        p++;
        p = json_skip_ws(p);
        while (*p && *p != '}') {
            char *key = NULL;
            p = json_parse_string(p, &key);
            if (!p) break;
            p = json_skip_ws(p);
            if (*p == ':') p++;
            p = json_skip_ws(p);
            if (strcmp(key, "code") == 0) {
                code = (int)strtol(p, (char **)&p, 10);
            } else if (strcmp(key, "message") == 0) {
                char *val = NULL;
                p = json_parse_string(p, &val);
                if (val) {
                    strncpy(msgbuf, val, sizeof(msgbuf) - 1);
                    free(val);
                }
                if (!p) {
                    free(key);
                    break;
                }
            } else {
                p = json_skip(p);
                if (!p) {
                    free(key);
                    break;
                }
            }
            free(key);
            p = json_skip_ws(p);
            if (*p == ',') p++;
            p = json_skip_ws(p);
        }
    }
    free(text);
    return grpcdc_status_make(code, msgbuf);
}
GRPC_RUNTIME_EOF
)

(define c-client-body
#<<GRPC_RUNTIME_EOF
/* ---- client streams ---- */
struct grpcdc_stream {
    grpcdc_channel *channel;
    uint32_t id;
    bool sent_half_close;
    bool ended;
    grpcdc_status terminal;
    bool have_terminal;
    int64_t deadline_abs_ms; /* 0 = none */
    grpcdc_trace_context trace;
    const char *trace_path;
    bool trace_ended;
};

static void stream_end_trace(grpcdc_stream *s, const char *status) {
    if (!s->trace_ended) {
        s->trace_ended = true;
        grpcdc_trace_end("client", s->trace_path ? s->trace_path : "",
                         &s->trace, status);
    }
}

static const char *md_find(const grpcdc_kv *md, size_t count, const char *key) {
    if (!md) return NULL;
    for (size_t i = 0; i < count; i++) {
        if (md[i].key && strcmp(md[i].key, key) == 0) return md[i].value;
    }
    return NULL;
}

void grpcdc_channel_init(grpcdc_channel *ch, grpcdc_transport *transport) {
    ch->transport = transport;
    ch->next_stream_id = 1;
}

static grpcdc_status send_frame(grpcdc_channel *ch, uint8_t type,
                                uint32_t stream_id, const uint8_t *payload,
                                size_t len) {
    grpcdc_bytes frame;
    grpcdc_status st = grpcdc_encode_frame(type, stream_id, payload, len, &frame);
    if (!grpcdc_status_is_ok(st)) return st;
    int rc = ch->transport->send(ch->transport->ctx, frame.data, frame.len);
    grpcdc_bytes_free(&frame);
    if (rc != 0)
        return grpcdc_status_make(GRPCDC_UNAVAILABLE, "transport send failed");
    return grpcdc_ok();
}

static grpcdc_status send_data_message(grpcdc_channel *ch, uint32_t stream_id,
                                       const uint8_t *msg, size_t len) {
    grpcdc_bytes payload;
    grpcdc_status st = grpcdc_encode_data_message(msg, len, &payload);
    if (!grpcdc_status_is_ok(st)) return st;
    st = send_frame(ch, GRPCDC_FRAME_DATA, stream_id, payload.data, payload.len);
    grpcdc_bytes_free(&payload);
    return st;
}

grpcdc_status grpcdc_channel_open(grpcdc_channel *ch, const char *path,
                                  const uint8_t *req, size_t req_len,
                                  int send_first,
                                  const grpcdc_kv *md, size_t md_count,
                                  int64_t deadline_ms,
                                  grpcdc_stream **out) {
    grpcdc_stream *s = (grpcdc_stream *)calloc(1, sizeof(grpcdc_stream));
    s->channel = ch;
    s->id = ch->next_stream_id;
    ch->next_stream_id += 2;
    s->trace = grpcdc_trace_start("client", path,
                                  md_find(md, md_count, "traceparent"));
    s->trace_path = path;
    /* Merge caller metadata with grpc-timeout and traceparent. */
    grpcdc_kv *merged = NULL;
    size_t merged_count = md_count;
    char *timeout = NULL;
    char tpbuf[56];
    if (deadline_ms > 0 || s->trace.active) {
        merged = (grpcdc_kv *)malloc(sizeof(grpcdc_kv) * (md_count + 2));
        if (md_count) memcpy(merged, md, sizeof(grpcdc_kv) * md_count);
        merged_count = md_count;
        if (deadline_ms > 0) {
            timeout = grpcdc_encode_timeout(deadline_ms);
            merged[merged_count].key = "grpc-timeout";
            merged[merged_count].value = timeout;
            merged_count++;
        }
        if (s->trace.active) {
            grpcdc_format_traceparent(&s->trace, tpbuf);
            merged[merged_count].key = "traceparent";
            merged[merged_count].value = tpbuf;
            merged_count++;
        }
    }
    grpcdc_bytes headers;
    grpcdc_status st = grpcdc_headers_frame(
        s->id, path, merged ? merged : md, merged_count, &headers);
    free(merged);
    if (!grpcdc_status_is_ok(st)) {
        stream_end_trace(s, "UNAVAILABLE");
        free(timeout);
        free(s);
        return st;
    }
    int rc = ch->transport->send(ch->transport->ctx, headers.data, headers.len);
    grpcdc_bytes_free(&headers);
    if (rc != 0) {
        stream_end_trace(s, "UNAVAILABLE");
        free(timeout);
        free(s);
        return grpcdc_status_make(GRPCDC_UNAVAILABLE, "transport send failed");
    }
    if (send_first) {
        /* A zero-length message (req may be NULL when len is 0)
           is still one DATA frame: the peer waits for exactly one
           request message before responding. */
        st = send_data_message(ch, s->id, req, req_len);
        if (!grpcdc_status_is_ok(st)) {
            free(timeout);
            free(s);
            return st;
        }
        st = send_frame(ch, GRPCDC_FRAME_HALF_CLOSE, s->id, NULL, 0);
        s->sent_half_close = true;
        if (!grpcdc_status_is_ok(st)) {
            free(timeout);
            free(s);
            return st;
        }
    }
    if (deadline_ms > 0) s->deadline_abs_ms = grpcdc_now_ms() + deadline_ms;
    free(timeout);
    *out = s;
    return grpcdc_ok();
}

grpcdc_status grpcdc_stream_send(grpcdc_stream *s, const uint8_t *msg,
                                 size_t len) {
    if (s->sent_half_close)
        return grpcdc_status_make(GRPCDC_FAILED_PRECONDITION,
                                  "send after half-close");
    return send_data_message(s->channel, s->id, msg, len);
}

grpcdc_status grpcdc_stream_close_send(grpcdc_stream *s) {
    if (s->sent_half_close) return grpcdc_ok();
    s->sent_half_close = true;
    return send_frame(s->channel, GRPCDC_FRAME_HALF_CLOSE, s->id, NULL, 0);
}

int grpcdc_stream_recv(grpcdc_stream *s, grpcdc_bytes *out,
                       grpcdc_status *st) {
    if (s->ended) {
        if (s->have_terminal && !grpcdc_status_is_ok(s->terminal)) {
            *st = s->terminal;
            return -1;
        }
        return 0;
    }
    while (1) {
        uint8_t *raw = NULL;
        size_t raw_len = 0;
        int recv_rc;
        if (s->deadline_abs_ms > 0 && s->channel->transport->recv_until) {
            recv_rc = s->channel->transport->recv_until(
                s->channel->transport->ctx, &raw, &raw_len,
                s->deadline_abs_ms);
            if (recv_rc == -2) {
                /* Best-effort cancel, then report the deadline. */
                grpcdc_bytes rst;
                if (grpcdc_status_is_ok(grpcdc_status_frame(
                        GRPCDC_FRAME_RST, s->id,
                        grpcdc_status_make(GRPCDC_CANCELLED, "deadline exceeded"),
                        &rst))) {
                    s->channel->transport->send(s->channel->transport->ctx,
                                                rst.data, rst.len);
                    grpcdc_bytes_free(&rst);
                }
                s->ended = true;
                stream_end_trace(s, "DEADLINE_EXCEEDED");
                *st = grpcdc_status_make(GRPCDC_DEADLINE_EXCEEDED,
                                         "deadline exceeded");
                return -1;
            }
        } else {
            recv_rc = s->channel->transport->recv(s->channel->transport->ctx,
                                                  &raw, &raw_len);
        }
        if (recv_rc != 0) {
            s->ended = true;
            stream_end_trace(s, "UNAVAILABLE");
            *st = grpcdc_status_make(GRPCDC_UNAVAILABLE, "transport closed");
            return -1;
        }
        grpcdc_frame frame;
        grpcdc_status dst = grpcdc_decode_frame(raw, raw_len, &frame);
        if (!grpcdc_status_is_ok(dst)) {
            free(raw);
            *st = dst;
            return -1;
        }
        if (frame.stream_id != s->id) {
            free(raw);
            continue;
        }
        if (frame.type == GRPCDC_FRAME_DATA) {
            size_t offset = 0;
            grpcdc_status mst = grpcdc_decode_data_message(
                frame.payload, frame.payload_len, &offset, out);
            free(raw);
            if (!grpcdc_status_is_ok(mst)) {
                *st = mst;
                return -1;
            }
            *st = grpcdc_ok();
            return 1;
        }
        if (frame.type == GRPCDC_FRAME_TRAILERS) {
            grpcdc_status tst =
                grpcdc_parse_status_payload(frame.payload, frame.payload_len);
            free(raw);
            s->ended = true;
            s->terminal = tst;
            s->have_terminal = true;
            stream_end_trace(s, grpcdc_status_name(tst.code));
            if (grpcdc_status_is_ok(tst)) return 0;
            *st = tst;
            return -1;
        }
        if (frame.type == GRPCDC_FRAME_RST) {
            grpcdc_status tst =
                grpcdc_parse_status_payload(frame.payload, frame.payload_len);
            free(raw);
            s->ended = true;
            s->terminal = tst;
            s->have_terminal = true;
            stream_end_trace(s, grpcdc_status_name(tst.code));
            *st = tst;
            return -1;
        }
        free(raw); /* response HEADERS and others: keep reading */
    }
}

void grpcdc_stream_free(grpcdc_stream *s) { free(s); }

grpcdc_status grpcdc_channel_unary(grpcdc_channel *ch, const char *path,
                                   const uint8_t *req, size_t req_len,
                                   const grpcdc_kv *md, size_t md_count,
                                   int64_t deadline_ms,
                                   grpcdc_bytes *resp_out) {
    grpcdc_stream *s = NULL;
    grpcdc_status st = grpcdc_channel_open(ch, path, req, req_len, 1, md,
                                           md_count, deadline_ms, &s);
    if (!grpcdc_status_is_ok(st)) return st;
    grpcdc_bytes first;
    grpcdc_status rst = grpcdc_ok();
    int r = grpcdc_stream_recv(s, &first, &rst);
    if (r != 1) {
        grpcdc_stream_free(s);
        if (r == 0)
            return grpcdc_status_make(GRPCDC_INTERNAL, "missing response");
        return rst;
    }
    /* Expect clean end right after the single response. */
    grpcdc_bytes extra;
    grpcdc_status est = grpcdc_ok();
    int r2 = grpcdc_stream_recv(s, &extra, &est);
    grpcdc_stream_free(s);
    if (r2 == 1) {
        grpcdc_bytes_free(&extra);
        grpcdc_bytes_free(&first);
        return grpcdc_status_make(GRPCDC_INTERNAL, "too many responses");
    }
    if (r2 < 0) {
        grpcdc_bytes_free(&first);
        return est;
    }
    *resp_out = first;
    return grpcdc_ok();
}
GRPC_RUNTIME_EOF
)

(define c-server-body
#<<GRPC_RUNTIME_EOF
/* ---- server ---- */
typedef struct {
    const grpcdc_method_desc *desc;
    void *impl;
} server_method_entry;

typedef struct {
    char *full_name;
    server_method_entry *methods;
    size_t method_count;
} server_service_entry;

struct grpcdc_server {
    server_service_entry *services;
    size_t service_count;
};

typedef struct {
    uint32_t id;
    const server_method_entry *method;
    void *impl;
    grpcdc_bytes *requests;
    size_t request_count;
    size_t request_pos;
    grpcdc_transport *transport;
    bool headers_sent;
    grpcdc_kv *metadata;
    size_t metadata_count;
    char *path;
} server_stream_state;

struct grpcdc_server_stream {
    server_stream_state *state;
};

static grpcdc_status server_send_frame(server_stream_state *ss, uint8_t type,
                                       const uint8_t *payload, size_t len) {
    grpcdc_bytes frame;
    grpcdc_status st = grpcdc_encode_frame(type, ss->id, payload, len, &frame);
    if (!grpcdc_status_is_ok(st)) return st;
    int rc = ss->transport->send(ss->transport->ctx, frame.data, frame.len);
    grpcdc_bytes_free(&frame);
    if (rc != 0)
        return grpcdc_status_make(GRPCDC_UNAVAILABLE, "transport send failed");
    return grpcdc_ok();
}

static grpcdc_status server_send_headers(server_stream_state *ss) {
    if (ss->headers_sent) return grpcdc_ok();
    ss->headers_sent = true;
    grpcdc_bytes frame;
    grpcdc_status st = grpcdc_headers_frame(ss->id, NULL, NULL, 0, &frame);
    if (!grpcdc_status_is_ok(st)) return st;
    int rc = ss->transport->send(ss->transport->ctx, frame.data, frame.len);
    grpcdc_bytes_free(&frame);
    if (rc != 0)
        return grpcdc_status_make(GRPCDC_UNAVAILABLE, "transport send failed");
    return grpcdc_ok();
}

static grpcdc_status server_send_trailers(server_stream_state *ss,
                                          grpcdc_status status) {
    grpcdc_bytes frame;
    grpcdc_status st =
        grpcdc_status_frame(GRPCDC_FRAME_TRAILERS, ss->id, status, &frame);
    if (!grpcdc_status_is_ok(st)) return st;
    int rc = ss->transport->send(ss->transport->ctx, frame.data, frame.len);
    grpcdc_bytes_free(&frame);
    if (rc != 0)
        return grpcdc_status_make(GRPCDC_UNAVAILABLE, "transport send failed");
    return grpcdc_ok();
}

grpcdc_status grpcdc_server_stream_send(grpcdc_server_stream *s,
                                        const uint8_t *msg, size_t len) {
    grpcdc_status st = server_send_headers(s->state);
    if (!grpcdc_status_is_ok(st)) return st;
    grpcdc_bytes payload;
    st = grpcdc_encode_data_message(msg, len, &payload);
    if (!grpcdc_status_is_ok(st)) return st;
    st = server_send_frame(s->state, GRPCDC_FRAME_DATA, payload.data,
                           payload.len);
    grpcdc_bytes_free(&payload);
    return st;
}

void grpcdc_server_stream_metadata(grpcdc_server_stream *s,
                                   const grpcdc_kv **md, size_t *md_count) {
    *md = s->state->metadata;
    *md_count = s->state->metadata_count;
}

int grpcdc_server_stream_recv(grpcdc_server_stream *s, grpcdc_bytes *out,
                              grpcdc_status *st) {
    server_stream_state *ss = s->state;
    if (ss->request_pos < ss->request_count) {
        *out = ss->requests[ss->request_pos];
        ss->requests[ss->request_pos].data = NULL; /* ownership moved */
        ss->requests[ss->request_pos].len = 0;
        ss->request_pos++;
        *st = grpcdc_ok();
        return 1;
    }
    return 0;
}

grpcdc_server *grpcdc_server_new(void) {
    return (grpcdc_server *)calloc(1, sizeof(grpcdc_server));
}

void grpcdc_server_add_service(grpcdc_server *srv, const char *full_name,
                               const grpcdc_method_desc *methods,
                               size_t method_count, void *impl) {
    srv->services = (server_service_entry *)realloc(
        srv->services, sizeof(server_service_entry) * (srv->service_count + 1));
    server_service_entry *svc = &srv->services[srv->service_count++];
    size_t n = strlen(full_name);
    svc->full_name = (char *)malloc(n + 1);
    memcpy(svc->full_name, full_name, n + 1);
    svc->methods =
        (server_method_entry *)malloc(sizeof(server_method_entry) * method_count);
    svc->method_count = method_count;
    for (size_t i = 0; i < method_count; i++) {
        svc->methods[i].desc = &methods[i];
        svc->methods[i].impl = impl;
    }
}

void grpcdc_server_free(grpcdc_server *srv) {
    if (!srv) return;
    for (size_t i = 0; i < srv->service_count; i++) {
        free(srv->services[i].full_name);
        free(srv->services[i].methods);
    }
    free(srv->services);
    free(srv);
}

static const server_method_entry *server_find(grpcdc_server *srv,
                                              const char *path) {
    /* path: /<service>/<method> */
    if (!path || path[0] != '/') return NULL;
    const char *slash = strrchr(path, '/');
    if (!slash) return NULL;
    size_t svc_len = (size_t)(slash - (path + 1));
    const char *method = slash + 1;
    for (size_t i = 0; i < srv->service_count; i++) {
        if (strlen(srv->services[i].full_name) == svc_len &&
            strncmp(srv->services[i].full_name, path + 1, svc_len) == 0) {
            for (size_t j = 0; j < srv->services[i].method_count; j++)
                if (strcmp(srv->services[i].methods[j].desc->name, method) == 0)
                    return &srv->services[i].methods[j];
            return NULL;
        }
    }
    return NULL;
}

static void server_dispatch(grpcdc_server *srv, server_stream_state *ss) {
    (void)srv;
    grpcdc_trace_context trace = grpcdc_trace_start(
        "server", ss->path ? ss->path : "",
        md_find(ss->metadata, ss->metadata_count, "traceparent"));
    grpcdc_status st = grpcdc_ok();
    grpcdc_server_stream raw;
    raw.state = ss;
    switch (ss->method->desc->kind) {
        case 0: {
            if (ss->request_count < 1) {
                st = grpcdc_status_make(GRPCDC_INVALID_ARGUMENT,
                                        "missing request");
                break;
            }
            grpcdc_bytes resp = {0};
            st = ss->method->desc->unary(ss->method->impl, ss->metadata,
                                         ss->metadata_count, ss->requests[0],
                                         &resp);
            if (grpcdc_status_is_ok(st)) {
                server_send_headers(ss);
                grpcdc_bytes payload;
                grpcdc_status est =
                    grpcdc_encode_data_message(resp.data, resp.len, &payload);
                if (grpcdc_status_is_ok(est)) {
                    server_send_frame(ss, GRPCDC_FRAME_DATA, payload.data,
                                      payload.len);
                    grpcdc_bytes_free(&payload);
                }
                grpcdc_bytes_free(&resp);
            }
            break;
        }
        case 1: {
            if (ss->request_count < 1) {
                st = grpcdc_status_make(GRPCDC_INVALID_ARGUMENT,
                                        "missing request");
                break;
            }
            st = ss->method->desc->server_stream(
                ss->method->impl, ss->metadata, ss->metadata_count,
                ss->requests[0], &raw);
            break;
        }
        case 2: {
            grpcdc_bytes resp = {0};
            st = ss->method->desc->client_stream(ss->method->impl, &raw, &resp);
            if (grpcdc_status_is_ok(st)) {
                server_send_headers(ss);
                grpcdc_bytes payload;
                grpcdc_status est =
                    grpcdc_encode_data_message(resp.data, resp.len, &payload);
                if (grpcdc_status_is_ok(est)) {
                    server_send_frame(ss, GRPCDC_FRAME_DATA, payload.data,
                                      payload.len);
                    grpcdc_bytes_free(&payload);
                }
                grpcdc_bytes_free(&resp);
            }
            break;
        }
        default: {
            st = ss->method->desc->bidi(ss->method->impl, &raw);
            break;
        }
    }
    grpcdc_trace_end("server", ss->path ? ss->path : "", &trace,
                     grpcdc_status_name(st.code));
    server_send_trailers(ss, st);
}

grpcdc_status grpcdc_server_serve(grpcdc_server *srv,
                                  grpcdc_transport *transport) {
    /* One active stream at a time (blocking call model). Frames for
       other stream ids are ignored until the active stream ends. */
    server_stream_state *active = NULL;
    while (1) {
        uint8_t *raw = NULL;
        size_t raw_len = 0;
        if (transport->recv(transport->ctx, &raw, &raw_len) != 0) {
            free(active);
            return grpcdc_status_make(GRPCDC_UNAVAILABLE, "transport closed");
        }
        grpcdc_frame frame;
        grpcdc_status dst = grpcdc_decode_frame(raw, raw_len, &frame);
        if (!grpcdc_status_is_ok(dst)) {
            free(raw);
            continue;
        }
        if (frame.type == GRPCDC_FRAME_HEADERS) {
            grpcdc_headers headers;
            grpcdc_status pst =
                grpcdc_parse_headers(frame.payload, frame.payload_len, &headers);
            if (!grpcdc_status_is_ok(pst) || !headers.path) {
                grpcdc_headers_free(&headers);
                free(raw);
                continue;
            }
            if (active) {
                grpcdc_bytes rst;
                grpcdc_status rst_st = grpcdc_status_frame(
                    GRPCDC_FRAME_RST, frame.stream_id,
                    grpcdc_status_make(GRPCDC_INTERNAL,
                                       "HEADERS for stream already in use"),
                    &rst);
                if (grpcdc_status_is_ok(rst_st)) {
                    transport->send(transport->ctx, rst.data, rst.len);
                    grpcdc_bytes_free(&rst);
                }
                grpcdc_headers_free(&headers);
                free(raw);
                continue;
            }
            const server_method_entry *method = server_find(srv, headers.path);
            if (!method) {
                char msg[300];
                snprintf(msg, sizeof(msg), "unknown method %s", headers.path);
                grpcdc_bytes tr;
                grpcdc_status tr_st = grpcdc_status_frame(
                    GRPCDC_FRAME_TRAILERS, frame.stream_id,
                    grpcdc_status_make(GRPCDC_UNIMPLEMENTED, msg), &tr);
                if (grpcdc_status_is_ok(tr_st)) {
                    transport->send(transport->ctx, tr.data, tr.len);
                    grpcdc_bytes_free(&tr);
                }
                grpcdc_headers_free(&headers);
                free(raw);
                continue;
            }
            active = (server_stream_state *)calloc(1, sizeof(server_stream_state));
            active->id = frame.stream_id;
            active->method = method;
            active->impl = method->impl;
            active->transport = transport;
            if (headers.path) {
                size_t plen = strlen(headers.path) + 1;
                active->path = (char *)malloc(plen);
                memcpy(active->path, headers.path, plen);
            }
            active->metadata = headers.metadata;
            active->metadata_count = headers.metadata_count;
            headers.metadata = NULL;
            headers.metadata_count = 0;
            grpcdc_headers_free(&headers);
            free(raw);
            continue;
        }
        if (!active || frame.stream_id != active->id) {
            free(raw);
            continue;
        }
        if (frame.type == GRPCDC_FRAME_DATA) {
            /* One DATA frame carries exactly one message (SPEC.md);
               a zero-length payload is a valid empty message. */
            size_t offset = 0;
            grpcdc_bytes msg;
            grpcdc_status mst = grpcdc_decode_data_message(
                frame.payload, frame.payload_len, &offset, &msg);
            if (grpcdc_status_is_ok(mst)) {
                active->requests = (grpcdc_bytes *)realloc(
                    active->requests,
                    sizeof(grpcdc_bytes) * (active->request_count + 1));
                active->requests[active->request_count++] = msg;
            }
            free(raw);
            continue;
        }
        if (frame.type == GRPCDC_FRAME_HALF_CLOSE) {
            /* Send response HEADERS first (others send headers up
               front), then run the handler to completion. */
            server_stream_state *done = active;
            active = NULL;
            server_send_headers(done);
            server_dispatch(srv, done);
            for (size_t i = 0; i < done->request_count; i++)
                grpcdc_bytes_free(&done->requests[i]);
            free(done->requests);
            for (size_t i = 0; i < done->metadata_count; i++) {
                free((void *)done->metadata[i].key);
                free((void *)done->metadata[i].value);
            }
            free(done->metadata);
            free(done->path);
            free(done);
            free(raw);
            continue;
        }
        if (frame.type == GRPCDC_FRAME_RST) {
            for (size_t i = 0; i < active->request_count; i++)
                grpcdc_bytes_free(&active->requests[i]);
            free(active->requests);
            free(active);
            active = NULL;
            free(raw);
            continue;
        }
        free(raw);
    }
}
GRPC_RUNTIME_EOF
)

(define c-memory-header
#<<GRPC_RUNTIME_EOF
#ifndef GRPCDC_MEMORY_TRANSPORT_H
#define GRPCDC_MEMORY_TRANSPORT_H

#include "grpcdc.h"

#ifdef __cplusplus
extern "C" {
#endif

/* In-memory transport pair for tests: two endpoints whose sent
   messages are queued for the peer to receive. Not thread-safe;
   drive both sides from one thread via the blocking call model. */
typedef struct grpcdc_memory_pair grpcdc_memory_pair;

grpcdc_memory_pair *grpcdc_memory_pair_new(void);
/* Fills *a and *b with transports connected to each other. */
void grpcdc_memory_pair_transports(grpcdc_memory_pair *pair,
                                   grpcdc_transport *a, grpcdc_transport *b);
void grpcdc_memory_pair_free(grpcdc_memory_pair *pair);

#ifdef __cplusplus
}
#endif

#endif /* GRPCDC_MEMORY_TRANSPORT_H */
GRPC_RUNTIME_EOF
)

(define c-memory-body
#<<GRPC_RUNTIME_EOF
#include "memory_transport.h"

#include <pthread.h>
#include <time.h>

typedef struct mem_queue {
    grpcdc_bytes *items;
    size_t count;
    size_t cap;
    bool closed;
    pthread_mutex_t mutex;
    pthread_cond_t cond;
} mem_queue;

static void mem_queue_init(mem_queue *q) {
    memset(q, 0, sizeof(*q));
    pthread_mutex_init(&q->mutex, NULL);
    pthread_cond_init(&q->cond, NULL);
}

struct grpcdc_memory_pair {
    mem_queue a_to_b;
    mem_queue b_to_a;
};

typedef struct {
    grpcdc_memory_pair *pair;
    mem_queue *inbox;
    mem_queue *outbox;
} mem_endpoint;

static int mem_send(void *ctx, const uint8_t *data, size_t len) {
    mem_endpoint *ep = (mem_endpoint *)ctx;
    pthread_mutex_lock(&ep->outbox->mutex);
    if (ep->outbox->closed) {
        pthread_mutex_unlock(&ep->outbox->mutex);
        return -1;
    }
    if (ep->outbox->count == ep->outbox->cap) {
        size_t cap = ep->outbox->cap ? ep->outbox->cap * 2 : 8;
        ep->outbox->items =
            (grpcdc_bytes *)realloc(ep->outbox->items, sizeof(grpcdc_bytes) * cap);
        ep->outbox->cap = cap;
    }
    grpcdc_bytes *slot = &ep->outbox->items[ep->outbox->count++];
    slot->data = (uint8_t *)malloc(len ? len : 1);
    slot->len = len;
    if (len) memcpy(slot->data, data, len);
    pthread_cond_signal(&ep->outbox->cond);
    pthread_mutex_unlock(&ep->outbox->mutex);
    return 0;
}

static int mem_recv(void *ctx, uint8_t **out, size_t *len) {
    mem_endpoint *ep = (mem_endpoint *)ctx;
    pthread_mutex_lock(&ep->inbox->mutex);
    while (ep->inbox->count == 0 && !ep->inbox->closed)
        pthread_cond_wait(&ep->inbox->cond, &ep->inbox->mutex);
    if (ep->inbox->count == 0) {
        pthread_mutex_unlock(&ep->inbox->mutex);
        return -1;
    }
    grpcdc_bytes first = ep->inbox->items[0];
    memmove(ep->inbox->items, ep->inbox->items + 1,
            sizeof(grpcdc_bytes) * (ep->inbox->count - 1));
    ep->inbox->count--;
    pthread_mutex_unlock(&ep->inbox->mutex);
    *out = first.data;
    *len = first.len;
    return 0;
}

static int mem_recv_until(void *ctx, uint8_t **out, size_t *len,
                          int64_t abs_deadline_ms) {
    mem_endpoint *ep = (mem_endpoint *)ctx;
    pthread_mutex_lock(&ep->inbox->mutex);
    while (ep->inbox->count == 0 && !ep->inbox->closed) {
        struct timespec ts;
        ts.tv_sec = (time_t)(abs_deadline_ms / 1000);
        ts.tv_nsec = (long)((abs_deadline_ms % 1000) * 1000000);
        if (pthread_cond_timedwait(&ep->inbox->cond, &ep->inbox->mutex,
                                   &ts) != 0)
            break;
    }
    if (ep->inbox->count == 0) {
        int rc = ep->inbox->closed ? -1 : -2;
        pthread_mutex_unlock(&ep->inbox->mutex);
        return rc;
    }
    grpcdc_bytes first = ep->inbox->items[0];
    memmove(ep->inbox->items, ep->inbox->items + 1,
            sizeof(grpcdc_bytes) * (ep->inbox->count - 1));
    ep->inbox->count--;
    pthread_mutex_unlock(&ep->inbox->mutex);
    *out = first.data;
    *len = first.len;
    return 0;
}

grpcdc_memory_pair *grpcdc_memory_pair_new(void) {
    grpcdc_memory_pair *pair =
        (grpcdc_memory_pair *)calloc(1, sizeof(grpcdc_memory_pair));
    mem_queue_init(&pair->a_to_b);
    mem_queue_init(&pair->b_to_a);
    return pair;
}

void grpcdc_memory_pair_transports(grpcdc_memory_pair *pair,
                                   grpcdc_transport *a, grpcdc_transport *b) {
    mem_endpoint *ea = (mem_endpoint *)calloc(1, sizeof(mem_endpoint));
    ea->pair = pair;
    ea->inbox = &pair->b_to_a;
    ea->outbox = &pair->a_to_b;
    mem_endpoint *eb = (mem_endpoint *)calloc(1, sizeof(mem_endpoint));
    eb->pair = pair;
    eb->inbox = &pair->a_to_b;
    eb->outbox = &pair->b_to_a;
    a->ctx = ea;
    a->send = mem_send;
    a->recv = mem_recv;
    a->recv_until = mem_recv_until;
    b->ctx = eb;
    b->send = mem_send;
    b->recv = mem_recv;
    b->recv_until = mem_recv_until;
}

void grpcdc_memory_pair_free(grpcdc_memory_pair *pair) {
    if (!pair) return;
    for (size_t i = 0; i < pair->a_to_b.count; i++)
        free(pair->a_to_b.items[i].data);
    for (size_t i = 0; i < pair->b_to_a.count; i++)
        free(pair->b_to_a.items[i].data);
    free(pair->a_to_b.items);
    free(pair->b_to_a.items);
    free(pair);
}
GRPC_RUNTIME_EOF
)


(define c-sidecar-header
#<<GRPC_RUNTIME_EOF
#ifndef GRPCDC_SIDECAR_TRANSPORT_H
#define GRPCDC_SIDECAR_TRANSPORT_H

#include "grpcdc.h"

#ifdef __cplusplus
extern "C" {
#endif

/* Transport over the Rust WebRTC-Direct sidecar: the sidecar
   owns DTLS/SCTP/TURN and bridges one datachannel to a local
   TCP socket using u32 big-endian length-prefixed messages
   (one prefix per DataChannel message). POSIX sockets only;
   host must be an IPv4 literal (the sidecar is local). */
typedef struct grpcdc_sidecar grpcdc_sidecar;

grpcdc_sidecar *grpcdc_sidecar_connect(const char *host, uint16_t port);
/* Fills *transport with the sidecar transport. */
void grpcdc_sidecar_transport(grpcdc_sidecar *sidecar, grpcdc_transport *transport);
void grpcdc_sidecar_free(grpcdc_sidecar *sidecar);

#ifdef __cplusplus
}
#endif

#endif /* GRPCDC_SIDECAR_TRANSPORT_H */
GRPC_RUNTIME_EOF
)

(define c-sidecar-body
#<<GRPC_RUNTIME_EOF
#include "sidecar_transport.h"

#include <arpa/inet.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

struct grpcdc_sidecar {
    int fd;
    uint8_t *buf;
    size_t len;
    size_t cap;
};

static int write_all(int fd, const uint8_t *data, size_t len) {
    size_t off = 0;
    while (off < len) {
        ssize_t n = send(fd, data + off, len - off, 0);
        if (n <= 0) return -1;
        off += (size_t)n;
    }
    return 0;
}

static int fill(grpcdc_sidecar *s, size_t need) {
    uint8_t tmp[65536];
    while (s->len < need) {
        ssize_t n = recv(s->fd, tmp, sizeof(tmp), 0);
        if (n <= 0) return -1;
        if (s->len + (size_t)n > s->cap) {
            size_t cap = (s->len + (size_t)n) * 2;
            s->buf = (uint8_t *)realloc(s->buf, cap);
            s->cap = cap;
        }
        memcpy(s->buf + s->len, tmp, (size_t)n);
        s->len += (size_t)n;
    }
    return 0;
}

static int sidecar_send(void *ctx, const uint8_t *data, size_t len) {
    grpcdc_sidecar *s = (grpcdc_sidecar *)ctx;
    uint8_t header[4] = {(uint8_t)(len >> 24), (uint8_t)(len >> 16),
                         (uint8_t)(len >> 8), (uint8_t)len};
    if (write_all(s->fd, header, 4) != 0) return -1;
    return write_all(s->fd, data, len);
}

static int sidecar_recv(void *ctx, uint8_t **out, size_t *len) {
    grpcdc_sidecar *s = (grpcdc_sidecar *)ctx;
    if (fill(s, 4) != 0) return -1;
    size_t payload_len = ((size_t)s->buf[0] << 24) | ((size_t)s->buf[1] << 16) |
                         ((size_t)s->buf[2] << 8) | (size_t)s->buf[3];
    memmove(s->buf, s->buf + 4, s->len - 4);
    s->len -= 4;
    if (fill(s, payload_len) != 0) return -1;
    *out = (uint8_t *)malloc(payload_len ? payload_len : 1);
    memcpy(*out, s->buf, payload_len);
    memmove(s->buf, s->buf + payload_len, s->len - payload_len);
    s->len -= payload_len;
    *len = payload_len;
    return 0;
}

grpcdc_sidecar *grpcdc_sidecar_connect(const char *host, uint16_t port) {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return NULL;
    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_port = htons(port);
    if (inet_pton(AF_INET, host, &addr.sin_addr) != 1) {
        close(fd);
        return NULL;
    }
    if (connect(fd, (struct sockaddr *)&addr, sizeof(addr)) != 0) {
        close(fd);
        return NULL;
    }
    grpcdc_sidecar *s = (grpcdc_sidecar *)calloc(1, sizeof(*s));
    s->fd = fd;
    return s;
}

void grpcdc_sidecar_transport(grpcdc_sidecar *sidecar, grpcdc_transport *transport) {
    transport->ctx = sidecar;
    transport->send = sidecar_send;
    transport->recv = sidecar_recv;
    transport->recv_until = NULL;
}

void grpcdc_sidecar_free(grpcdc_sidecar *sidecar) {
    if (!sidecar) return;
    close(sidecar->fd);
    free(sidecar->buf);
    free(sidecar);
}
GRPC_RUNTIME_EOF
)

(define (emit-c-runtime-files)
  (define header
    (string-replace
     (string-replace c-header-body "@@FRAME_CONSTS@@" (stamp-frame-consts))
     "@@STATUS_CONSTS@@" (stamp-status-consts)))
  (list
   (cons "grpcdc/grpcdc.h" header)
   (cons "grpcdc/grpcdc.c"
         (string-append "#include \"grpcdc.h\"\n\n"
                        ;; strip duplicate include line inside bodies
                        (string-replace (substring c-impl-body (string-length "#include \"grpcdc.h\"\n\n"))
                                        "@@STATUS_NAMES@@" (stamp-status-names))
                        "\n"
                        (substring c-client-body 0 (string-length c-client-body))
                        "\n"
                        c-server-body))
   (cons "grpcdc/memory_transport.h" c-memory-header)
   (cons "grpcdc/sidecar_transport.h" c-sidecar-header)
   (cons "grpcdc/sidecar_transport.c" c-sidecar-body)
   (cons "grpcdc/memory_transport.c" c-memory-body)))
