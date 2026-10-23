/* Interop harness: the C echo client over stdio. Prints one line
   per call shape to stderr (stdout carries frames) and exits
   non-zero on any failure. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "echo_grpc_dc.h"
#include "stdio_transport.h"

static int fail(const char *what, grpcdc_status st) {
    fprintf(stderr, "%s status: %d %s\n", what, st.code, st.message);
    return 1;
}

int main(void) {
    stdio_transport stdio;
    stdio_transport_init(&stdio, STDIN_FILENO, STDOUT_FILENO);
    grpcdc_transport transport = stdio_transport_iface(&stdio);
    grpcdc_channel channel;
    grpcdc_channel_init(&channel, &transport);
    EchoClient client;
    client.channel = &channel;

    EchoRequest req;
    EchoRequest_init(&req);
    req.message = "hello";
    EchoResponse resp;
    grpcdc_status st = EchoClient_unary(&client, &req, &resp, NULL, 0, 0);
    if (!grpcdc_status_is_ok(st)) return fail("unary", st);
    fprintf(stderr, "unary=%s\n", resp.message);

    req.message = "tick";
    req.count = 3;
    EchoServerStreamClient stream;
    st = EchoClient_server_stream(&client, &req, &stream, NULL, 0, 0);
    if (!grpcdc_status_is_ok(st)) return fail("server_stream", st);
    char ticks[256] = "";
    int first = 1;
    for (;;) {
        EchoResponse tick;
        grpcdc_status rst;
        int r = EchoServerStreamClient_recv(&stream, &tick, &rst);
        if (r == 0) break;
        if (r < 0) return fail("server_stream recv", rst);
        char tmp[128];
        snprintf(tmp, sizeof(tmp), "%s%s#%d", first ? "" : ",", tick.message,
                 tick.index);
        strcat(ticks, tmp);
        first = 0;
    }
    EchoServerStreamClient_close(&stream);
    fprintf(stderr, "server_stream=%s\n", ticks);

    EchoRequest parts[3];
    const char *names[3] = {"a", "b", "c"};
    for (int i = 0; i < 3; i++) {
        EchoRequest_init(&parts[i]);
        parts[i].message = (char *)names[i];
    }
    EchoResponse joined;
    st = EchoClient_client_stream(&client, parts, 3, &joined, NULL, 0, 0);
    if (!grpcdc_status_is_ok(st)) return fail("client_stream", st);
    fprintf(stderr, "client_stream=%s\n", joined.message);

    EchoRequest xy[2];
    const char *xynames[2] = {"x", "y"};
    for (int i = 0; i < 2; i++) {
        EchoRequest_init(&xy[i]);
        xy[i].message = (char *)xynames[i];
    }
    EchoBidiClient bidi;
    st = EchoClient_bidi(&client, xy, 2, &bidi, NULL, 0, 0);
    if (!grpcdc_status_is_ok(st)) return fail("bidi", st);
    char echoed[256] = "";
    first = 1;
    for (;;) {
        EchoResponse one;
        grpcdc_status rst;
        int r = EchoBidiClient_recv(&bidi, &one, &rst);
        if (r == 0) break;
        if (r < 0) return fail("bidi recv", rst);
        if (!first) strcat(echoed, ",");
        strcat(echoed, one.message);
        first = 0;
    }
    EchoBidiClient_close(&bidi);
    fprintf(stderr, "bidi=%s\n", echoed);

    EchoRequest hello;
    EchoRequest_init(&hello);
    hello.message = "hello";
    grpcdc_kv md[1] = {{"x-echo", "meta"}};
    EchoResponse md_resp;
    st = EchoClient_unary(&client, &hello, &md_resp, md, 1, 0);
    if (!grpcdc_status_is_ok(st)) return fail("metadata", st);
    fprintf(stderr, "metadata=%s\n", md_resp.message);

    EchoRequest slow;
    EchoRequest_init(&slow);
    slow.message = "slow";
    slow.delay_ms = 400;
    EchoResponse slow_resp;
    st = EchoClient_unary(&client, &slow, &slow_resp, NULL, 0, 50);
    if (grpcdc_status_is_ok(st))
        fprintf(stderr, "deadline=no error\n");
    else
        fprintf(stderr, "deadline=%d\n", st.code);

    EchoRequest fail_req;
    EchoRequest_init(&fail_req);
    fail_req.message = "fail";
    EchoResponse fail_resp;
    st = EchoClient_unary(&client, &fail_req, &fail_resp, NULL, 0, 0);
    if (grpcdc_status_is_ok(st)) {
        fprintf(stderr, "error_case=no error\n");
        return 1;
    }
    fprintf(stderr, "error_case=%s: %s\n", grpcdc_status_name(st.code),
            st.message);
    return 0;
}
