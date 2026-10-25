/* Reference Echo implementation for the C harness (mirrors the
   other language demos): "fail" is rejected, everything else
   echoes. Response strings are malloc'd; the generated adapters
   marshal them before the next call, and this header's helpers
   free what they allocate per call. */
#ifndef GRPCDC_ECHO_SERVICE_IMPL_H
#define GRPCDC_ECHO_SERVICE_IMPL_H

#include <stdlib.h>
#include <string.h>
#include <time.h>

#include "echo_grpc_dc.h"

static char *echo_strdup(const char *s) {
    size_t n = strlen(s);
    char *out = (char *)malloc(n + 1);
    memcpy(out, s, n + 1);
    return out;
}

static grpcdc_status echo_unary_impl(void *ctx, const grpcdc_kv *md,
                                     size_t md_count, const EchoRequest *req,
                                     EchoResponse *resp) {
    (void)ctx;
    if (strcmp(req->message, "fail") == 0)
        return grpcdc_status_make(GRPCDC_INVALID_ARGUMENT, "asked to fail");
    if (req->delay_ms > 0) {
        struct timespec ts;
        ts.tv_sec = req->delay_ms / 1000;
        ts.tv_nsec = (long)(req->delay_ms % 1000) * 1000000L;
        nanosleep(&ts, NULL);
    }
    const char *marker = "";
    const char *trailer_marker = "";
    for (size_t i = 0; i < md_count; i++) {
        if (strcmp(md[i].key, "x-echo") == 0) marker = md[i].value;
        if (strcmp(md[i].key, "x-echo-trailer") == 0) trailer_marker = md[i].value;
    }
    size_t n = strlen(req->message);
    size_t m = strlen(marker);
    char *out = (char *)malloc(n + m + 10);
    size_t len = 0;
    memcpy(out, "echo: ", 6);
    len = 6;
    memcpy(out + len, req->message, n);
    len += n;
    if (m > 0) {
        memcpy(out + len, " [", 2);
        len += 2;
        memcpy(out + len, marker, m);
        len += m;
        out[len++] = ']';
    }
    out[len] = 0;
    resp->message = out;
    resp->index = 0;
    grpcdc_status st = grpcdc_ok();
    if (trailer_marker[0]) {
        st.trailers[0].key = "x-echo-trailer";
        st.trailers[0].value = trailer_marker;
        st.trailers_count = 1;
    }
    return st;
}

static grpcdc_status echo_server_stream_impl(void *ctx, const grpcdc_kv *md,
                                             size_t md_count,
                                             const EchoRequest *req,
                                             EchoServerStreamStream *stream) {
    (void)ctx;
    (void)md;
    (void)md_count;
    if (strcmp(req->message, "fail") == 0)
        return grpcdc_status_make(GRPCDC_INVALID_ARGUMENT, "asked to fail");
    for (int32_t i = 0; i < req->count; i++) {
        EchoResponse resp;
        memset(&resp, 0, sizeof(resp));
        resp.message = (char *)req->message;
        resp.index = i;
        grpcdc_status st = EchoServerStreamStream_send(stream, &resp);
        if (!grpcdc_status_is_ok(st)) return st;
    }
    return grpcdc_ok();
}

static grpcdc_status echo_client_stream_impl(void *ctx,
                                             EchoClientStreamStream *stream,
                                             EchoResponse *resp) {
    (void)ctx;
    size_t cap = 64, len = 0;
    char *joined = (char *)malloc(cap);
    joined[0] = 0;
    int32_t count = 0;
    while (1) {
        EchoRequest req;
        grpcdc_status st;
        int r = EchoClientStreamStream_recv(stream, &req, &st);
        if (r == 0) break;
        if (r < 0) {
            free(joined);
            return st;
        }
        size_t n = strlen(req.message);
        size_t need = len + n + 2;
        if (need > cap) {
            while (cap < need) cap *= 2;
            joined = (char *)realloc(joined, cap);
        }
        if (count > 0) joined[len++] = '+';
        memcpy(joined + len, req.message, n + 1);
        len += n;
        count++;
    }
    resp->message = joined;
    resp->index = count;
    return grpcdc_ok();
}

static grpcdc_status echo_bidi_impl(void *ctx, EchoBidiStream *stream) {
    (void)ctx;
    int32_t index = 0;
    while (1) {
        EchoRequest req;
        grpcdc_status st;
        int r = EchoBidiStream_recv(stream, &req, &st);
        if (r == 0) return grpcdc_ok();
        if (r < 0) return st;
        if (strcmp(req.message, "fail") == 0)
            return grpcdc_status_make(GRPCDC_INVALID_ARGUMENT, "asked to fail");
        EchoResponse resp;
        memset(&resp, 0, sizeof(resp));
        resp.message = (char *)req.message;
        resp.index = index++;
        st = EchoBidiStream_send(stream, &resp);
        if (!grpcdc_status_is_ok(st)) return st;
    }
}

static EchoServerImpl echo_server_impl = {
    NULL,
    echo_unary_impl,
    echo_server_stream_impl,
    echo_client_stream_impl,
    echo_bidi_impl,
};

#endif /* GRPCDC_ECHO_SERVICE_IMPL_H */
