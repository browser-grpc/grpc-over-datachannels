/* Test driver for the C runtime and generated code.
   Usage: tests <TestCodec|TestEcho|TestPbMessages|TestBdd> */
#include <assert.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#if defined(__unix__) || defined(__APPLE__)
#define GRPCDC_POSIX 1
#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <signal.h>
#include <sys/socket.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>
#endif

#include "../examples/echo_service_impl.h"
#include "../examples/stdio_transport.h"
#include "grpcdc/dynamic.h"
#include "bdd_scenarios.h"
#include "bdd_schemas.h"
#include "oracle_scenarios.h"
#include "features_messages.h"
#include "kitchen_messages.h"
#include "grpcdc/memory_transport.h"
#include "grpcdc/sidecar_transport.h"
#include "../examples/interop/test_grpc_dc.h"
#include "../examples/interop/orca_grpc_dc.h"
#include "interop_cases.h"
static void check(int cond, const char *what) {
    if (!cond) {
        fprintf(stderr, "FAIL: %s\n", what);
        exit(1);
    }
}

#include "test_eventbus.h"

static void test_codec(void) {
    /* HEADERS frame golden bytes (same vectors as other languages). */
    grpcdc_kv md[1] = {{"x-echo", "on"}};
    grpcdc_bytes frame;
    grpcdc_status st = grpcdc_headers_frame(1, "/echo.Echo/Unary", md, 1, &frame);
    check(grpcdc_status_is_ok(st), "headers encode");
    static const uint8_t expected_head[] = {1, 0, 0, 0, 1};
    check(frame.len > 9 && memcmp(frame.data, expected_head, 5) == 0,
          "headers frame prefix");
    grpcdc_frame decoded;
    st = grpcdc_decode_frame(frame.data, frame.len, &decoded);
    check(grpcdc_status_is_ok(st) && decoded.type == 1 &&
              decoded.stream_id == 1,
          "headers frame decode");
    grpcdc_headers headers;
    st = grpcdc_parse_headers(decoded.payload, decoded.payload_len, &headers);
    check(grpcdc_status_is_ok(st) && headers.path &&
              strcmp(headers.path, "/echo.Echo/Unary") == 0,
          "headers path");
    const char *marker = grpcdc_headers_get(&headers, "x-echo");
    check(marker && strcmp(marker, "on") == 0, "headers metadata");
    grpcdc_headers_free(&headers);
    grpcdc_bytes_free(&frame);

    /* DATA payloads are raw messages on this wire (SPEC.md). */
    grpcdc_bytes data;
    st = grpcdc_encode_data_message((const uint8_t *)"\x0a\x05hello", 7, &data);
    check(grpcdc_status_is_ok(st) && data.len == 7 &&
              memcmp(data.data, "\x0a\x05hello", 7) == 0,
          "data message encode");
    size_t offset = 0;
    grpcdc_bytes msg;
    st = grpcdc_decode_data_message(data.data, data.len, &offset, &msg);
    check(grpcdc_status_is_ok(st) && msg.len == 7 &&
              memcmp(msg.data, "\x0a\x05hello", 7) == 0 && offset == 7,
          "data message decode");
    grpcdc_bytes_free(&msg);
    grpcdc_bytes_free(&data);

    /* Status frame round-trip. */
    grpcdc_bytes sf;
    st = grpcdc_status_frame(GRPCDC_FRAME_TRAILERS, 3,
                             grpcdc_status_make(GRPCDC_INVALID_ARGUMENT,
                                                "asked to fail"),
                             &sf);
    check(grpcdc_status_is_ok(st), "status frame encode");
    grpcdc_frame sf_decoded;
    st = grpcdc_decode_frame(sf.data, sf.len, &sf_decoded);
    check(grpcdc_status_is_ok(st), "status frame decode");
    grpcdc_status parsed =
        grpcdc_parse_status_payload(sf_decoded.payload, sf_decoded.payload_len);
    check(parsed.code == GRPCDC_INVALID_ARGUMENT &&
              strcmp(parsed.message, "asked to fail") == 0,
          "status payload parse");
    grpcdc_bytes_free(&sf);

    /* Timeout grammar. */
    char *t = grpcdc_encode_timeout(250);
    check(strcmp(t, "250m") == 0, "timeout encode ms");
    free(t);
    int64_t ms = 0;
    check(grpcdc_parse_timeout("100S", &ms) && ms == 100000,
          "timeout parse S");
    check(grpcdc_parse_timeout("999u", &ms) && ms == 1, "timeout parse u");

    printf("codec tests passed\n");
}

typedef struct {
    grpcdc_transport *transport;
} server_job;

static void *server_main(void *arg) {
    server_job *job = (server_job *)arg;
    grpcdc_server *server = grpcdc_server_new();
    EchoServer_register(server, &echo_server_impl);
    grpcdc_server_serve(server, job->transport);
    grpcdc_server_free(server);
    return NULL;
}

/* Slow counting handler + server for the stream-break test. */
static volatile int stream_break_produced;

static grpcdc_status stream_break_server_stream(void *ctx,
                                                const grpcdc_kv *md,
                                                size_t md_count,
                                                const EchoRequest *req,
                                                EchoServerStreamStream *stream) {
    (void)ctx;
    (void)md;
    (void)md_count;
    for (int32_t i = 0; i < req->count; i++) {
        EchoResponse resp;
        memset(&resp, 0, sizeof(resp));
        resp.message = (char *)req->message;
        resp.index = i;
        stream_break_produced++;
        grpcdc_status st = EchoServerStreamStream_send(stream, &resp);
        if (!grpcdc_status_is_ok(st)) return st;
        struct timespec ts;
        ts.tv_sec = 0;
        ts.tv_nsec = 10 * 1000000L;
        nanosleep(&ts, NULL);
    }
    return grpcdc_ok();
}

static EchoServerImpl stream_break_impl = {
    NULL, echo_unary_impl, stream_break_server_stream,
    echo_client_stream_impl, echo_bidi_impl};

static void *stream_break_server_main(void *arg) {
    server_job *job = (server_job *)arg;
    grpcdc_server *server = grpcdc_server_new();
    EchoServer_register(server, &stream_break_impl);
    grpcdc_server_serve(server, job->transport);
    grpcdc_server_free(server);
    return NULL;
}

static void test_echo(void) {
    grpcdc_memory_pair *pair = grpcdc_memory_pair_new();
    grpcdc_transport a, b;
    grpcdc_memory_pair_transports(pair, &a, &b);
    server_job job = {&b};
    pthread_t thread;
    check(pthread_create(&thread, NULL, server_main, &job) == 0,
          "server thread");

    grpcdc_channel channel;
    grpcdc_channel_init(&channel, &a);
    EchoClient client;
    client.channel = &channel;

    EchoRequest req;
    EchoRequest_init(&req);
    req.message = "hello";
    EchoResponse resp;
    grpcdc_status st = EchoClient_unary(&client, &req, &resp, NULL, 0, 0);
    check(grpcdc_status_is_ok(st), "unary status");
    check(strcmp(resp.message, "echo: hello") == 0, "unary body");

    req.message = "fail";
    EchoResponse fail_resp;
    st = EchoClient_unary(&client, &req, &fail_resp, NULL, 0, 0);
    check(st.code == GRPCDC_INVALID_ARGUMENT &&
              strcmp(st.message, "asked to fail") == 0,
          "unary fail status");

    req.message = "tick";
    req.count = 3;
    EchoServerStreamClient stream;
    st = EchoClient_server_stream(&client, &req, &stream, NULL, 0, 0);
    check(grpcdc_status_is_ok(st), "server stream open");
    for (int i = 0; i < 3; i++) {
        EchoResponse tick;
        grpcdc_status rst;
        int r = EchoServerStreamClient_recv(&stream, &tick, &rst);
        check(r == 1 && tick.index == i &&
                  strcmp(tick.message, "tick") == 0,
              "server stream tick");
    }
    {
        EchoResponse extra;
        grpcdc_status rst;
        check(EchoServerStreamClient_recv(&stream, &extra, &rst) == 0,
              "server stream end");
    }
    EchoServerStreamClient_close(&stream);

    EchoRequest parts[3];
    const char *names[3] = {"a", "b", "c"};
    for (int i = 0; i < 3; i++) {
        EchoRequest_init(&parts[i]);
        parts[i].message = (char *)names[i];
    }
    EchoResponse joined;
    st = EchoClient_client_stream(&client, parts, 3, &joined, NULL, 0, 0);
    check(grpcdc_status_is_ok(st) && strcmp(joined.message, "a+b+c") == 0 &&
              joined.index == 3,
          "client stream join");

    EchoRequest xy[2];
    const char *xyn[2] = {"x", "y"};
    for (int i = 0; i < 2; i++) {
        EchoRequest_init(&xy[i]);
        xy[i].message = (char *)xyn[i];
    }
    EchoBidiClient bidi;
    st = EchoClient_bidi(&client, xy, 2, &bidi, NULL, 0, 0);
    check(grpcdc_status_is_ok(st), "bidi open");
    for (int i = 0; i < 2; i++) {
        EchoResponse one;
        grpcdc_status rst;
        int r = EchoBidiClient_recv(&bidi, &one, &rst);
        check(r == 1 && strcmp(one.message, xyn[i]) == 0 && one.index == i,
              "bidi echo");
    }
    {
        EchoResponse extra;
        grpcdc_status rst;
        check(EchoBidiClient_recv(&bidi, &extra, &rst) == 0, "bidi end");
    }
    EchoBidiClient_close(&bidi);

    /* Breaking a server stream cancels it server-side: closing
       the client stream before trailers sends RST CANCELLED, and
       the handler's next send fails instead of producing forever. */
    {
        stream_break_produced = 0;
        grpcdc_memory_pair *break_pair = grpcdc_memory_pair_new();
        grpcdc_transport ba, bb;
        grpcdc_memory_pair_transports(break_pair, &ba, &bb);
        server_job break_job = {&bb};
        pthread_t break_thread;
        check(pthread_create(&break_thread, NULL, stream_break_server_main,
                             &break_job) == 0,
              "stream-break server thread");
        grpcdc_channel break_channel;
        grpcdc_channel_init(&break_channel, &ba);
        EchoClient break_client;
        break_client.channel = &break_channel;
        EchoRequest break_req;
        EchoRequest_init(&break_req);
        break_req.message = "tick";
        break_req.count = 200;
        EchoServerStreamClient break_stream;
        grpcdc_status bst = EchoClient_server_stream(
            &break_client, &break_req, &break_stream, NULL, 0, 0);
        check(grpcdc_status_is_ok(bst), "stream-break open");
        EchoResponse first;
        grpcdc_status rst;
        int r = EchoServerStreamClient_recv(&break_stream, &first, &rst);
        check(r == 1 && first.index == 0, "stream-break first response");
        EchoServerStreamClient_close(&break_stream); /* abandon: RST */
        struct timespec wait_ts;
        wait_ts.tv_sec = 0;
        wait_ts.tv_nsec = 100 * 1000000L;
        nanosleep(&wait_ts, NULL);
        int settled = stream_break_produced;
        nanosleep(&wait_ts, NULL);
        check(stream_break_produced == settled,
              "stream-break production did not settle");
        check(settled < 100, "stream-break server kept producing");
    }

#if defined(GRPCDC_POSIX)
    /* Same break over the sidecar (socket) transport: handler
       sends must poll for the RST (sidecar recv_until), or the
       abandoned call keeps producing into the socket. */
    {
        stream_break_produced = 0;
        int fds[2];
        check(socketpair(AF_UNIX, SOCK_STREAM, 0, fds) == 0,
              "sidecar stream-break socketpair");
        grpcdc_sidecar *side_a = grpcdc_sidecar_from_fd(fds[0]);
        grpcdc_sidecar *side_b = grpcdc_sidecar_from_fd(fds[1]);
        grpcdc_transport sa, sb;
        grpcdc_sidecar_transport(side_a, &sa);
        grpcdc_sidecar_transport(side_b, &sb);
        server_job side_job = {&sb};
        pthread_t side_thread;
        check(pthread_create(&side_thread, NULL, stream_break_server_main,
                             &side_job) == 0,
              "sidecar stream-break server thread");
        grpcdc_channel side_channel;
        grpcdc_channel_init(&side_channel, &sa);
        EchoClient side_client;
        side_client.channel = &side_channel;
        EchoRequest side_req;
        EchoRequest_init(&side_req);
        side_req.message = "tick";
        side_req.count = 200;
        EchoServerStreamClient side_stream;
        grpcdc_status sst = EchoClient_server_stream(
            &side_client, &side_req, &side_stream, NULL, 0, 0);
        check(grpcdc_status_is_ok(sst), "sidecar stream-break open");
        EchoResponse side_first;
        grpcdc_status side_rst;
        int sr = EchoServerStreamClient_recv(&side_stream, &side_first,
                                             &side_rst);
        check(sr == 1 && side_first.index == 0,
              "sidecar stream-break first response");
        EchoServerStreamClient_close(&side_stream); /* abandon: RST */
        struct timespec side_wait;
        side_wait.tv_sec = 0;
        side_wait.tv_nsec = 100 * 1000000L;
        nanosleep(&side_wait, NULL);
        int side_settled = stream_break_produced;
        nanosleep(&side_wait, NULL);
        check(stream_break_produced == side_settled,
              "sidecar stream-break production did not settle");
        check(side_settled < 100, "sidecar stream-break server kept producing");
    }
#endif

    printf("echo tests passed\n");
}

static int hexval(char c) {
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return 0;
}

static size_t unhex(const char *hex, uint8_t *out) {
    size_t n = strlen(hex) / 2;
    for (size_t i = 0; i < n; i++)
        out[i] = (uint8_t)(hexval(hex[2 * i]) * 16 + hexval(hex[2 * i + 1]));
    return n;
}

/* BDD schema scenarios: golden protoc bytes decoded by the
   generated classes must re-encode byte-identically
   (the schema scenarios). */
static void test_bdd_schemas(void) {
    static uint8_t input[8192];
    static uint8_t expect[8192];
    static uint8_t got[8192];
    for (unsigned i = 0; i < bdd_schema_cases_count; i++) {
        const bdd_schema_case *c = &bdd_schema_cases[i];
        size_t in_len = unhex(c->input, input);
        size_t expect_len = unhex(c->expect, expect);
        size_t got_len;
        char what[128];
        snprintf(what, sizeof(what), "bdd-schema %s", c->name);
        if (strcmp(c->message, "kitchen") == 0) {
            Kitchen msg;
            memset(&msg, 0, sizeof(msg));
            Kitchen_unmarshal(&msg, input, in_len);
            KitchenPbBytes bytes = Kitchen_marshal(&msg);
            got_len = bytes.len;
            memcpy(got, bytes.data, got_len);
            free(bytes.data);
        } else if (strcmp(c->message, "outer") == 0) {
            Outer msg;
            memset(&msg, 0, sizeof(msg));
            Outer_unmarshal(&msg, input, in_len);
            FeaturesPbBytes bytes = Outer_marshal(&msg);
            got_len = bytes.len;
            memcpy(got, bytes.data, got_len);
            free(bytes.data);
        } else {
            check(0, "bdd-schema: unknown message");
            return;
        }
        check(got_len == expect_len && memcmp(got, expect, expect_len) == 0, what);
    }
    printf("TestBddSchemas OK (%u scenarios)\n", bdd_schema_cases_count);
}

static void test_pb_messages(void) {
    /* Kitchen sink: scalars, nested, maps, repeated, oneof. */
    Kitchen k;
    Kitchen_init(&k);
    k.d = 1.5;
    k.i32 = -7;
    k.i64 = -9000000000LL;
    k.u64 = 123456789ULL;
    k.s32 = -33;
    k.f64 = 987654321ULL;
    k.flag = true;
    k.name = "sink";
    k.color = Color_GREEN;
    Nested nested;
    Nested_init(&nested);
    nested.note = "deep";
    nested.level = 42;
    k.nested = &nested;
    Item item;
    Item_init(&item);
    item.sku = "A-1";
    item.quantity = 4;
    k.item = &item;
    Kitchen_CountsEntry counts[2];
    memset(counts, 0, sizeof(counts));
    counts[0].key = "a";
    counts[0].value = 1;
    counts[1].key = "b";
    counts[1].value = 2;
    k.counts = counts;
    k.counts_count = 2;
    int32_t nums[3] = {1, -2, 300};
    k.nums = nums;
    k.nums_count = 3;
    k.code = 9;

    KitchenPbBytes bytes = Kitchen_marshal(&k);
    Kitchen back;
    memset(&back, 0, sizeof(back));
    Kitchen_unmarshal(&back, bytes.data, bytes.len);
    check(back.d == 1.5 && back.i32 == -7 && back.i64 == -9000000000LL &&
              back.u64 == 123456789ULL && back.s32 == -33 &&
              back.f64 == 987654321ULL && back.flag,
          "kitchen scalars");
    check(strcmp(back.name, "sink") == 0 && back.color == Color_GREEN,
          "kitchen name/enum");
    check(back.nested && back.nested->level == 42 &&
              strcmp(back.nested->note, "deep") == 0,
          "kitchen nested");
    check(back.item && strcmp(back.item->sku, "A-1") == 0 &&
              back.item->quantity == 4,
          "kitchen cross-file item");
    check(back.counts_count == 2, "kitchen map count");
    int found_a = 0, found_b = 0;
    for (size_t i = 0; i < back.counts_count; i++) {
        if (strcmp(back.counts[i].key, "a") == 0 && back.counts[i].value == 1)
            found_a = 1;
        if (strcmp(back.counts[i].key, "b") == 0 && back.counts[i].value == 2)
            found_b = 1;
    }
    check(found_a && found_b, "kitchen map values");
    check(back.nums_count == 3 && back.nums[0] == 1 && back.nums[1] == -2 &&
              back.nums[2] == 300,
          "kitchen packed nums");
    check(back.code == 9, "kitchen oneof scalar");
    free(bytes.data);

    /* Features: nested enum, deep nesting, enum map. */
    Outer outer;
    Outer_init(&outer);
    Outer_Middle middle;
    Outer_Middle_init(&middle);
    Outer_Middle_Inner inner;
    Outer_Middle_Inner_init(&inner);
    inner.v = "core";
    inner.n = 3;
    middle.inner = &inner;
    middle.kind = Outer_Middle_Kind_BETA;
    outer.middle = &middle;
    Outer_ShadesEntry shades[1];
    memset(shades, 0, sizeof(shades));
    shades[0].key = "sky";
    shades[0].value = Shade_DARK;
    outer.shades = shades;
    outer.shades_count = 1;
    outer.code = 5;
    FeaturesPbBytes obytes = Outer_marshal(&outer);
    Outer oback;
    memset(&oback, 0, sizeof(oback));
    Outer_unmarshal(&oback, obytes.data, obytes.len);
    check(oback.middle && oback.middle->kind == Outer_Middle_Kind_BETA &&
              oback.middle->inner &&
              strcmp(oback.middle->inner->v, "core") == 0 &&
              oback.middle->inner->n == 3,
          "features deep nesting");
    check(oback.shades_count == 1 &&
              strcmp(oback.shades[0].key, "sky") == 0 &&
              oback.shades[0].value == Shade_DARK,
          "features enum map");
    check(oback.code == 5, "features oneof");
    free(obytes.data);

    printf("pb message tests passed\n");
}

/* BDD: interprets the generated behavior scenarios (bdd_scenarios.h,
   generated from the BDD specification; prose in BDD.md) against a
   loopback client+server. The scenarios are the executable
   examples, so the documentation cannot drift from the behavior. */
static void test_bdd(void) {
    grpcdc_memory_pair *pair = grpcdc_memory_pair_new();
    grpcdc_transport a, b;
    grpcdc_memory_pair_transports(pair, &a, &b);
    server_job job = {&b};
    pthread_t thread;
    check(pthread_create(&thread, NULL, server_main, &job) == 0,
          "bdd server thread");

    grpcdc_channel channel;
    grpcdc_channel_init(&channel, &a);
    EchoClient client;
    client.channel = &channel;

    for (size_t ci = 0; ci < bdd_cases_count; ci++) {
        const bdd_case *c = &bdd_cases[ci];
        char what[128];
        if (strcmp(c->kind, "unary-trailer") == 0) {
            EchoRequest req;
            EchoRequest_init(&req);
            req.message = (char *)c->messages[0];
            grpcdc_kv md[1] = {{"x-echo-trailer", (char *)c->metadata}};
            EchoPbBytes rb = EchoRequest_marshal(&req);
            grpcdc_stream *raw = NULL;
            grpcdc_status ost = grpcdc_channel_open(&channel, "/echo.Echo/Unary",
                                                    rb.data, rb.len, 1, md, 1, 0,
                                                    &raw);
            free(rb.data);
            snprintf(what, sizeof(what), "bdd %s: trailer open", c->name);
            check(grpcdc_status_is_ok(ost), what);
            EchoResponse resp;
            memset(&resp, 0, sizeof(resp));
            grpcdc_bytes out;
            grpcdc_status rst;
            int r = grpcdc_stream_recv(raw, &out, &rst);
            if (r == 1) {
                EchoResponse_unmarshal(&resp, out.data, out.len);
                grpcdc_bytes_free(&out);
            }
            snprintf(what, sizeof(what), "bdd %s: trailer response", c->name);
            check(r == 1 && strcmp(resp.message, c->expect_message) == 0 &&
                      resp.index == c->expect_num,
                  what);
            grpcdc_status est;
            int e = grpcdc_stream_recv(raw, &out, &est);
            if (e == 1) grpcdc_bytes_free(&out);
            snprintf(what, sizeof(what), "bdd %s: trailer EOF", c->name);
            check(e == 0 && grpcdc_status_is_ok(est), what);
            size_t tcount = 0;
            const grpcdc_kv *trs = grpcdc_stream_trailers(raw, &tcount);
            const char *tval = NULL;
            for (size_t i = 0; i < tcount; i++)
                if (strcmp(trs[i].key, "x-echo-trailer") == 0) tval = trs[i].value;
            snprintf(what, sizeof(what), "bdd %s: trailer value", c->name);
            check(tval && strcmp(tval, c->metadata) == 0, what);
            grpcdc_stream_free(raw);
        } else if (strcmp(c->kind, "unary") == 0) {
            EchoRequest req;
            EchoRequest_init(&req);
            req.message = (char *)c->messages[0];
            grpcdc_kv md[1];
            size_t md_count = 0;
            if (c->metadata[0]) {
                md[0].key = "x-echo";
                md[0].value = (char *)c->metadata;
                md_count = 1;
            }
            EchoResponse resp;
            grpcdc_status st =
                EchoClient_unary(&client, &req, &resp, md, md_count, 0);
            snprintf(what, sizeof(what), "bdd %s: unary status", c->name);
            if (c->expect_status >= 0) {
                check(st.code == c->expect_status, what);
            } else {
                check(grpcdc_status_is_ok(st), what);
                snprintf(what, sizeof(what), "bdd %s: unary response", c->name);
                check(strcmp(resp.message, c->expect_message) == 0 &&
                          resp.index == c->expect_num,
                      what);
            }
        } else if (strcmp(c->kind, "server-stream") == 0) {
            EchoRequest req;
            EchoRequest_init(&req);
            req.message = (char *)c->messages[0];
            req.count = c->count;
            EchoServerStreamClient stream;
            grpcdc_status st =
                EchoClient_server_stream(&client, &req, &stream, NULL, 0, 0);
            snprintf(what, sizeof(what), "bdd %s: server-stream open", c->name);
            check(grpcdc_status_is_ok(st), what);
            int got = 0;
            while (1) {
                EchoResponse one;
                grpcdc_status rst;
                int r = EchoServerStreamClient_recv(&stream, &one, &rst);
                if (r == 0) break;
                snprintf(what, sizeof(what), "bdd %s: server-stream item",
                         c->name);
                check(r == 1 && strcmp(one.message, c->expect_message) == 0 &&
                          one.index == got,
                      what);
                got++;
            }
            snprintf(what, sizeof(what), "bdd %s: server-stream count", c->name);
            check(got == c->expect_num, what);
            EchoServerStreamClient_close(&stream);
        } else if (strcmp(c->kind, "client-stream") == 0) {
            EchoRequest parts[16];
            check(c->messages_count <= 16, "bdd: too many messages");
            for (size_t i = 0; i < c->messages_count; i++) {
                EchoRequest_init(&parts[i]);
                parts[i].message = (char *)c->messages[i];
            }
            EchoResponse resp;
            grpcdc_status st = EchoClient_client_stream(
                &client, parts, c->messages_count, &resp, NULL, 0, 0);
            snprintf(what, sizeof(what), "bdd %s: client-stream", c->name);
            check(grpcdc_status_is_ok(st) &&
                      strcmp(resp.message, c->expect_message) == 0 &&
                      resp.index == c->expect_num,
                  what);
        } else if (strcmp(c->kind, "bidi") == 0) {
            EchoRequest parts[16];
            check(c->messages_count <= 16, "bdd: too many messages");
            for (size_t i = 0; i < c->messages_count; i++) {
                EchoRequest_init(&parts[i]);
                parts[i].message = (char *)c->messages[i];
            }
            EchoBidiClient bidi;
            grpcdc_status st =
                EchoClient_bidi(&client, parts, c->messages_count, &bidi,
                                NULL, 0, 0);
            snprintf(what, sizeof(what), "bdd %s: bidi open", c->name);
            check(grpcdc_status_is_ok(st), what);
            for (size_t i = 0; i < c->messages_count; i++) {
                EchoResponse one;
                grpcdc_status rst;
                int r = EchoBidiClient_recv(&bidi, &one, &rst);
                snprintf(what, sizeof(what), "bdd %s: bidi echo", c->name);
                check(r == 1 && strcmp(one.message, c->messages[i]) == 0 &&
                          one.index == (int32_t)i,
                      what);
            }
            EchoResponse extra;
            grpcdc_status rst;
            snprintf(what, sizeof(what), "bdd %s: bidi end", c->name);
            check(EchoBidiClient_recv(&bidi, &extra, &rst) == 0, what);
            EchoBidiClient_close(&bidi);
        } else if (strcmp(c->kind, "server-stream-fail") == 0) {
            EchoRequest req;
            EchoRequest_init(&req);
            req.message = (char *)c->messages[0];
            req.count = c->count;
            EchoServerStreamClient stream;
            grpcdc_status st =
                EchoClient_server_stream(&client, &req, &stream, NULL, 0, 0);
            snprintf(what, sizeof(what), "bdd %s: server-stream-fail", c->name);
            if (grpcdc_status_is_ok(st)) {
                int failed = 0;
                while (1) {
                    EchoResponse one;
                    grpcdc_status rst;
                    int r = EchoServerStreamClient_recv(&stream, &one, &rst);
                    if (r == 0) break;
                    if (r < 0) {
                        check(rst.code == c->expect_status, what);
                        failed = 1;
                        break;
                    }
                }
                check(failed, what);
                EchoServerStreamClient_close(&stream);
            } else {
                check(st.code == c->expect_status, what);
            }
        } else if (strcmp(c->kind, "bidi-fail") == 0) {
            EchoRequest parts[16];
            check(c->messages_count <= 16, "bdd: too many messages");
            for (size_t i = 0; i < c->messages_count; i++) {
                EchoRequest_init(&parts[i]);
                parts[i].message = (char *)c->messages[i];
            }
            EchoBidiClient bidi;
            grpcdc_status st =
                EchoClient_bidi(&client, parts, c->messages_count, &bidi,
                                NULL, 0, 0);
            snprintf(what, sizeof(what), "bdd %s: bidi-fail", c->name);
            if (grpcdc_status_is_ok(st)) {
                int failed = 0;
                while (1) {
                    EchoResponse one;
                    grpcdc_status rst;
                    int r = EchoBidiClient_recv(&bidi, &one, &rst);
                    if (r == 0) break;
                    if (r < 0) {
                        check(rst.code == c->expect_status, what);
                        failed = 1;
                        break;
                    }
                }
                check(failed, what);
                EchoBidiClient_close(&bidi);
            } else {
                check(st.code == c->expect_status, what);
            }
        } else if (strcmp(c->kind, "deadline") == 0) {
            EchoRequest req;
            EchoRequest_init(&req);
            req.message = (char *)c->messages[0];
            req.delay_ms = c->count;
            EchoResponse resp;
            grpcdc_status st =
                EchoClient_unary(&client, &req, &resp, NULL, 0, 100);
            snprintf(what, sizeof(what), "bdd %s: deadline", c->name);
            check(st.code == c->expect_status, what);
        } else if (strcmp(c->kind, "cancel") == 0) {
            EchoRequest req;
            EchoRequest_init(&req);
            req.message = (char *)c->messages[0];
            req.count = c->count;
            EchoPbBytes bytes = EchoRequest_marshal(&req);
            grpcdc_stream *stream = NULL;
            grpcdc_status st = grpcdc_channel_open(
                &channel, "/echo.Echo/ServerStream", bytes.data, bytes.len,
                1, NULL, 0, 0, &stream);
            free(bytes.data);
            snprintf(what, sizeof(what), "bdd %s: cancel open", c->name);
            check(grpcdc_status_is_ok(st), what);
            grpcdc_bytes first;
            grpcdc_status rst;
            int r = grpcdc_stream_recv(stream, &first, &rst);
            snprintf(what, sizeof(what), "bdd %s: cancel first", c->name);
            check(r == 1, what);
            grpcdc_bytes_free(&first);
            grpcdc_stream_free(stream);
            /* Freeing the stream aborts the call; completing the
               test without a hang is the termination proof. */
        } else if (strcmp(c->kind, "stream-break") == 0) {
            /* Dedicated counting server: closing the client
               stream (no explicit cancel) must RST the call so
               the server stops producing. */
            stream_break_produced = 0;
            grpcdc_memory_pair *break_pair = grpcdc_memory_pair_new();
            grpcdc_transport ba, bb;
            grpcdc_memory_pair_transports(break_pair, &ba, &bb);
            server_job break_job = {&bb};
            pthread_t break_thread;
            snprintf(what, sizeof(what), "bdd %s: break server thread",
                     c->name);
            check(pthread_create(&break_thread, NULL,
                                 stream_break_server_main,
                                 &break_job) == 0,
                  what);
            grpcdc_channel break_channel;
            grpcdc_channel_init(&break_channel, &ba);
            EchoClient break_client;
            break_client.channel = &break_channel;
            EchoRequest req;
            EchoRequest_init(&req);
            req.message = (char *)c->messages[0];
            req.count = c->count;
            EchoServerStreamClient stream;
            grpcdc_status st = EchoClient_server_stream(
                &break_client, &req, &stream, NULL, 0, 0);
            snprintf(what, sizeof(what), "bdd %s: stream-break open",
                     c->name);
            check(grpcdc_status_is_ok(st), what);
            EchoResponse first;
            grpcdc_status rst;
            int r = EchoServerStreamClient_recv(&stream, &first, &rst);
            snprintf(what, sizeof(what), "bdd %s: stream-break first",
                     c->name);
            check(r == 1 && strcmp(first.message, c->messages[0]) == 0 &&
                      first.index == 0,
                  what);
            EchoServerStreamClient_close(&stream); /* abandon: RST */
            struct timespec wait_ts;
            wait_ts.tv_sec = 0;
            wait_ts.tv_nsec = 150 * 1000000L;
            nanosleep(&wait_ts, NULL);
            int settled = stream_break_produced;
            nanosleep(&wait_ts, NULL);
            snprintf(what, sizeof(what),
                     "bdd %s: production did not settle", c->name);
            check(stream_break_produced == settled, what);
            snprintf(what, sizeof(what),
                     "bdd %s: server kept producing", c->name);
            check(settled < 50, what);
        } else if (strcmp(c->kind, "raw-unary") == 0) {
            EchoRequest req;
            EchoRequest_init(&req);
            req.message = (char *)c->messages[0];
            EchoPbBytes bytes = EchoRequest_marshal(&req);
            grpcdc_bytes resp_bytes;
            grpcdc_status st = grpcdc_channel_unary(
                &channel, c->path, bytes.data, bytes.len, NULL, 0, 0,
                &resp_bytes);
            free(bytes.data);
            snprintf(what, sizeof(what), "bdd %s: raw-unary status", c->name);
            check(c->expect_status >= 0 && st.code == c->expect_status, what);
        } else {
            snprintf(what, sizeof(what), "bdd %s: unknown kind %s", c->name,
                     c->kind);
            check(0, what);
        }
    }
    printf("bdd tests passed (%zu scenarios)\n", bdd_cases_count);
}

#ifdef GRPCDC_POSIX
/* ---- TestOracle helpers: spawn the grpc-java oracle and the
   Node bridge exactly like the other languages' TestOracle. ---- */

typedef struct {
    pid_t pid;
    int stdin_fd;  /* parent writes -> child stdin */
    int stdout_fd; /* parent reads <- child stdout */
    int stderr_fd; /* parent reads <- child stderr */
} child_proc;

static int spawn_child(char *const argv[], child_proc *ch) {
    int in_pipe[2], out_pipe[2], err_pipe[2];
    if (pipe(in_pipe) || pipe(out_pipe) || pipe(err_pipe)) return -1;
    pid_t pid = fork();
    if (pid < 0) return -1;
    if (pid == 0) {
        dup2(in_pipe[0], STDIN_FILENO);
        dup2(out_pipe[1], STDOUT_FILENO);
        dup2(err_pipe[1], STDERR_FILENO);
        close(in_pipe[0]); close(in_pipe[1]);
        close(out_pipe[0]); close(out_pipe[1]);
        close(err_pipe[0]); close(err_pipe[1]);
        execvp(argv[0], argv);
        _exit(127);
    }
    close(in_pipe[0]); close(out_pipe[1]); close(err_pipe[1]);
    ch->pid = pid;
    ch->stdin_fd = in_pipe[1];
    ch->stdout_fd = out_pipe[0];
    ch->stderr_fd = err_pipe[0];
    return 0;
}

static void kill_child(child_proc *ch) {
    if (ch->pid > 0) {
        kill(ch->pid, SIGKILL);
        int status;
        while (waitpid(ch->pid, &status, 0) < 0 && errno == EINTR) {
        }
        ch->pid = -1;
    }
    if (ch->stdin_fd >= 0) close(ch->stdin_fd);
    if (ch->stdout_fd >= 0) close(ch->stdout_fd);
    if (ch->stderr_fd >= 0) close(ch->stderr_fd);
    ch->stdin_fd = ch->stdout_fd = ch->stderr_fd = -1;
}

/* Read fd until needle appears or timeout; returns 1 when found.
   Consumed text is drained into sink (may be NULL). */
static int wait_for_text(int fd, const char *needle, int timeout_ms,
                         char *sink, size_t sink_cap) {
    size_t used = 0;
    if (sink && sink_cap) sink[0] = 0;
    int flags = fcntl(fd, F_GETFL, 0);
    fcntl(fd, F_SETFL, flags | O_NONBLOCK);
    int waited = 0;
    char chunk[1024];
    while (waited < timeout_ms) {
        ssize_t n = read(fd, chunk, sizeof(chunk) - 1);
        if (n > 0) {
            chunk[n] = 0;
            if (sink && sink_cap) {
                size_t room = sink_cap - 1 - used;
                size_t take = (size_t)n < room ? (size_t)n : room;
                memcpy(sink + used, chunk, take);
                used += take;
                sink[used] = 0;
                if (strstr(sink, needle)) return 1;
            } else if (strstr(chunk, needle)) {
                return 1;
            }
        } else if (n == 0) {
            return 0; /* EOF */
        } else {
            if (errno != EAGAIN && errno != EWOULDBLOCK) return 0;
            struct timespec ts = {0, 20 * 1000 * 1000};
            nanosleep(&ts, NULL);
            waited += 20;
        }
    }
    return 0;
}

/* Concurrent drainer: appends fd to EOF into the sink. Used to
   pump a child's stdout and stderr at the same time so the child
   never blocks on a full pipe while we wait (cf. the C++ and
   Java server-oracle harnesses draining both streams on
   threads). */
typedef struct {
    int fd;
    char *sink;
    size_t sink_cap;
} drain_job;

static void *drain_main(void *arg) {
    drain_job *job = (drain_job *)arg;
    size_t used = 0;
    if (job->sink && job->sink_cap) job->sink[0] = 0;
    char chunk[1024];
    ssize_t n;
    while ((n = read(job->fd, chunk, sizeof(chunk) - 1)) > 0) {
        if (job->sink && job->sink_cap) {
            size_t room = job->sink_cap - 1 - used;
            size_t take = (size_t)n < room ? (size_t)n : room;
            memcpy(job->sink + used, chunk, take);
            used += take;
            job->sink[used] = 0;
        }
    }
    return NULL;
}

/* Drain fd to EOF (blocking) into sink. */
static void drain_fd(int fd, char *sink, size_t sink_cap) {
    size_t used = 0;
    if (sink && sink_cap) sink[0] = 0;
    char chunk[1024];
    ssize_t n;
    while ((n = read(fd, chunk, sizeof(chunk) - 1)) > 0) {
        if (sink && sink_cap) {
            size_t room = sink_cap - 1 - used;
            size_t take = (size_t)n < room ? (size_t)n : room;
            memcpy(sink + used, chunk, take);
            used += take;
            sink[used] = 0;
        }
    }
}

static int wait_exit(child_proc *ch, int timeout_ms) {
    int waited = 0;
    int status;
    while (waited < timeout_ms) {
        pid_t r = waitpid(ch->pid, &status, WNOHANG);
        if (r == ch->pid) {
            ch->pid = -1;
            return WIFEXITED(status) ? WEXITSTATUS(status) : -1;
        }
        struct timespec ts = {0, 20 * 1000 * 1000};
        nanosleep(&ts, NULL);
        waited += 20;
    }
    kill_child(ch);
    return -1;
}

static int free_port(void) {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return 0;
    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    addr.sin_port = 0;
    if (bind(fd, (struct sockaddr *)&addr, sizeof(addr)) != 0) {
        close(fd);
        return 0;
    }
    socklen_t len = sizeof(addr);
    int port = 0;
    if (getsockname(fd, (struct sockaddr *)&addr, &len) == 0)
        port = ntohs(addr.sin_port);
    close(fd);
    return port;
}

static int file_exists(const char *path) { return access(path, F_OK) == 0; }

/* Repository root: GRPC_DC_ROOT, else walk up from cwd looking for
   fixtures/echo_descriptor_set.bin (same rule as other drivers). */
static void find_root(char *out, size_t cap) {
    const char *env = getenv("GRPC_DC_ROOT");
    if (env && env[0]) {
        snprintf(out, cap, "%s", env);
        return;
    }
    char prefix[64] = ".";
    for (int depth = 0; depth < 8; depth++) {
        char probe[1024];
        snprintf(probe, sizeof(probe), "%s/fixtures/echo_descriptor_set.bin",
                 prefix);
        if (file_exists(probe)) {
            snprintf(out, cap, "%s", prefix);
            return;
        }
        snprintf(probe, sizeof(probe),
                 "%s/grpc-over-datachannels/fixtures/echo_descriptor_set.bin",
                 prefix);
        if (file_exists(probe)) {
            snprintf(out, cap, "%s/grpc-over-datachannels", prefix);
            return;
        }
        char next[64];
        snprintf(next, sizeof(next), "%s/..", prefix);
        snprintf(prefix, sizeof(prefix), "%s", next);
    }
    snprintf(out, cap, ".");
}

/* classes dir + cp.txt contents, like test_util.javaClasspath. */
static int java_classpath(const char *root, char *out, size_t cap) {
    char classes[1024], cp_path[1024];
    snprintf(classes, sizeof(classes), "%s/oracle/java/target/classes", root);
    snprintf(cp_path, sizeof(cp_path), "%s/oracle/java/target/cp.txt", root);
    if (!file_exists(classes) || !file_exists(cp_path)) return 0;
    FILE *f = fopen(cp_path, "r");
    if (!f) return 0;
    char cp[8192];
    size_t n = fread(cp, 1, sizeof(cp) - 1, f);
    fclose(f);
    cp[n] = 0;
    while (n > 0 && (cp[n - 1] == '\n' || cp[n - 1] == '\r' ||
                     cp[n - 1] == ' ' || cp[n - 1] == '\t'))
        cp[--n] = 0;
    snprintf(out, cap, "%s:%s", classes, cp);
    return 1;
}

static const char *unmsg(const char *token) {
    return strcmp(token, "-") == 0 ? "" : token;
}

/* The shared Echo expectation rules over the generated oracle
   scenario table (mirrors scenario_runner in other languages). */
static void run_oracle_cases(EchoClient *client) {
    for (size_t ci = 0; ci < oracle_cases_count; ci++) {
        const oracle_case *c = &oracle_cases[ci];
        char what[128];
        if (strcmp(c->kind, "UNARY") == 0) {
            const char *msg = unmsg(c->messages[0]);
            EchoRequest req;
            EchoRequest_init(&req);
            req.message = (char *)msg;
            EchoResponse resp;
            grpcdc_status st =
                EchoClient_unary(client, &req, &resp, NULL, 0, 0);
            snprintf(what, sizeof(what), "oracle UNARY: status");
            if (c->expect_status >= 0) {
                check(st.code == c->expect_status, what);
            } else {
                check(grpcdc_status_is_ok(st), what);
                char want[256];
                snprintf(want, sizeof(want), "echo: %s", msg);
                check(strcmp(resp.message, want) == 0 && resp.index == 0,
                      "oracle UNARY: response");
            }
        } else if (strcmp(c->kind, "SERVER_STREAM") == 0) {
            const char *msg = unmsg(c->messages[0]);
            EchoRequest req;
            EchoRequest_init(&req);
            req.message = (char *)msg;
            req.count = c->count;
            EchoServerStreamClient stream;
            grpcdc_status st =
                EchoClient_server_stream(client, &req, &stream, NULL, 0, 0);
            check(grpcdc_status_is_ok(st), "oracle SERVER_STREAM: open");
            int got = 0;
            while (1) {
                EchoResponse one;
                grpcdc_status rst;
                int r = EchoServerStreamClient_recv(&stream, &one, &rst);
                if (r == 0) break;
                check(r == 1 && strcmp(one.message, msg) == 0 &&
                          one.index == got,
                      "oracle SERVER_STREAM: response");
                got++;
            }
            check(got == c->count, "oracle SERVER_STREAM: count");
            EchoServerStreamClient_close(&stream);
        } else if (strcmp(c->kind, "CLIENT_STREAM") == 0) {
            EchoRequest parts[16];
            check(c->messages_count <= 16, "oracle: too many messages");
            char want[512] = "";
            for (size_t i = 0; i < c->messages_count; i++) {
                EchoRequest_init(&parts[i]);
                parts[i].message = (char *)unmsg(c->messages[i]);
                if (i) strcat(want, "+");
                strcat(want, parts[i].message);
            }
            EchoResponse resp;
            grpcdc_status st = EchoClient_client_stream(
                client, parts, c->messages_count, &resp, NULL, 0, 0);
            check(grpcdc_status_is_ok(st) &&
                      strcmp(resp.message, want) == 0 &&
                      resp.index == (int32_t)c->messages_count,
                  "oracle CLIENT_STREAM: response");
        } else if (strcmp(c->kind, "BIDI") == 0) {
            EchoRequest parts[16];
            check(c->messages_count <= 16, "oracle: too many messages");
            for (size_t i = 0; i < c->messages_count; i++) {
                EchoRequest_init(&parts[i]);
                parts[i].message = (char *)unmsg(c->messages[i]);
            }
            EchoBidiClient bidi;
            grpcdc_status st =
                EchoClient_bidi(client, parts, c->messages_count, &bidi,
                                NULL, 0, 0);
            check(grpcdc_status_is_ok(st), "oracle BIDI: open");
            for (size_t i = 0; i < c->messages_count; i++) {
                EchoResponse one;
                grpcdc_status rst;
                int r = EchoBidiClient_recv(&bidi, &one, &rst);
                check(r == 1 &&
                          strcmp(one.message, unmsg(c->messages[i])) == 0 &&
                          one.index == (int32_t)i,
                      "oracle BIDI: echo");
            }
            EchoResponse extra;
            grpcdc_status rst;
            check(EchoBidiClient_recv(&bidi, &extra, &rst) == 0,
                  "oracle BIDI: end");
            EchoBidiClient_close(&bidi);
        }
    }
}

/* Direction A plumbing shared by TestOracle and TestDynamic:
   this client -> Node bridge (dc-to-http2) -> official server.
   Returns 1 with a ready channel, 0 when unavailable (caller
   prints its SKIP line). */
typedef struct {
    child_proc server;
    child_proc bridge;
    stdio_transport transport;
    grpcdc_transport iface;
    grpcdc_channel channel;
} oracle_dir_a;

static int oracle_dir_a_start(const char *root, const char *cp,
                              oracle_dir_a *oa) {
    char bridge[1024];
    snprintf(bridge, sizeof(bridge), "%s/oracle/bridge.mjs", root);
    if (!file_exists(bridge)) return 0;
    int port = free_port();
    char port_str[16];
    snprintf(port_str, sizeof(port_str), "%d", port);
    char *server_argv[] = {"java", "-cp", (char *)cp,
                           "dc.oracle.OracleServer", port_str, NULL};
    oa->server = (child_proc){-1, -1, -1, -1};
    oa->bridge = (child_proc){-1, -1, -1, -1};
    if (spawn_child(server_argv, &oa->server) != 0 ||
        !wait_for_text(oa->server.stderr_fd, "READY", 60000, NULL, 0)) {
        kill_child(&oa->server);
        return 0;
    }
    char grpc_addr[64];
    snprintf(grpc_addr, sizeof(grpc_addr), "127.0.0.1:%d", port);
    char *bridge_argv[] = {"node", bridge, "dc-to-http2", "--grpc",
                           grpc_addr, NULL};
    if (spawn_child(bridge_argv, &oa->bridge) != 0) {
        kill_child(&oa->server);
        return 0;
    }
    stdio_transport_init(&oa->transport, oa->bridge.stdout_fd,
                         oa->bridge.stdin_fd);
    oa->iface = stdio_transport_iface(&oa->transport);
    grpcdc_channel_init(&oa->channel, &oa->iface);
    return 1;
}

static void oracle_dir_a_stop(oracle_dir_a *oa) {
    kill_child(&oa->bridge);
    kill_child(&oa->server);
}

/* Oracle: official grpc-java, bridged over TCP<->DataChannel by
   oracle/bridge.mjs, must agree with the C runtime on every case of
   the generated scenario table. Skips when the Java oracle or Node
   bridge are unavailable (Dockerfile.ci provides both). */
static void test_oracle(void) {
    char root[1024];
    find_root(root, sizeof(root));
    char cp[8192];
    if (!java_classpath(root, cp, sizeof(cp))) {
        printf("TestOracle SKIP (java oracle not built)\n");
        return;
    }
    oracle_dir_a oa;
    if (!oracle_dir_a_start(root, cp, &oa)) {
        printf("TestOracle SKIP (oracle server did not start)\n");
        return;
    }
    {
        EchoClient client;
        client.channel = &oa.channel;
        run_oracle_cases(&client);
    }
    oracle_dir_a_stop(&oa);

    /* Direction B: official client -> bridge -> this server. */
    char server_bin[1024];
    snprintf(server_bin, sizeof(server_bin), "%s/c/build/echo_server_stdio",
             root);
    if (!file_exists(server_bin)) {
        printf("TestOracle SKIP (c server not built)\n");
        return;
    }
    int port_b = free_port();
    char port_b_str[16];
    snprintf(port_b_str, sizeof(port_b_str), "%d", port_b);
    char bridge_b_path[1024];
    snprintf(bridge_b_path, sizeof(bridge_b_path), "%s/oracle/bridge.mjs",
             root);
    char *bridge_b_argv[] = {"node", bridge_b_path, "http2-to-dc", "--port",
                             port_b_str, "--target-cmd", server_bin, NULL};
    child_proc bridge_b = {-1, -1, -1, -1};
    if (spawn_child(bridge_b_argv, &bridge_b) != 0 ||
        !wait_for_text(bridge_b.stderr_fd, "listening", 60000, NULL, 0)) {
        kill_child(&bridge_b);
        printf("TestOracle SKIP (bridge B did not start)\n");
        return;
    }
    char scenarios[1024];
    snprintf(scenarios, sizeof(scenarios), "%s/fixtures/oracle_scenarios.txt",
             root);
    char *client_argv[] = {"java", "-cp", cp, "dc.oracle.OracleClient",
                           port_b_str, scenarios, NULL};
    child_proc client_proc = {-1, -1, -1, -1};
    if (spawn_child(client_argv, &client_proc) != 0) {
        kill_child(&bridge_b);
        printf("TestOracle SKIP (oracle client did not start)\n");
        return;
    }
    /* Close our copies of the client's stdin so it sees EOF. */
    close(client_proc.stdin_fd);
    client_proc.stdin_fd = -1;
    static char client_out[65536];
    drain_fd(client_proc.stdout_fd, client_out, sizeof(client_out));
    int exit_code = wait_exit(&client_proc, 120000);
    check(exit_code == 0, "oracle client failed");
    check(strstr(client_out, "ORACLE CLIENT: ALL OK") != NULL,
          "oracle client output");
    kill_child(&bridge_b);
    printf("oracle tests passed (%zu scenarios, both directions)\n",
           oracle_cases_count);
}
/* ---- TestInteropOracle: the generated interop case table
   (interop_cases.h) against the official grpc-java
   TestServiceServer, driven from main() only by name. ---- */
static Payload *ic_payload(int size) {
    Payload *p = (Payload *)calloc(1, sizeof(Payload));
    Payload_init(p);
    p->type = PayloadType_COMPRESSABLE;
    if (size > 0) {
        p->body.data = (uint8_t *)calloc((size_t)size, 1);
        p->body.len = (size_t)size;
    }
    return p;
}

static StreamingOutputCallRequest *ic_out_reqs(const InteropCase *c) {
    StreamingOutputCallRequest *reqs =
        (StreamingOutputCallRequest *)calloc(4, sizeof(StreamingOutputCallRequest));
    for (int i = 0; i < c->resp_count; i++) {
        StreamingOutputCallRequest_init(&reqs[i]);
        reqs[i].response_parameters =
            (ResponseParameters *)calloc(4, sizeof(ResponseParameters));
        reqs[i].response_parameters_count = (size_t)c->resp_count;
        for (int j = 0; j < c->resp_count; j++) {
            ResponseParameters_init(&reqs[i].response_parameters[j]);
            reqs[i].response_parameters[j].size = c->resp_sizes[j];
        }
    }
    return reqs;
}

static const char *ic_kv_get(const grpcdc_kv *kvs, size_t count, const char *key) {
    for (size_t i = 0; i < count; i++)
        if (strcmp(kvs[i].key, key) == 0) return kvs[i].value;
    return NULL;
}

static void run_interop_cases(TestServiceClient *client,
                              UnimplementedServiceClient *unimpl) {
    static const char *INITIAL_KEY = "x-grpc-test-echo-initial";
    static const char *INITIAL_VAL = "test_initial_metadata_value";
    static const char *TRAILER_KEY = "x-grpc-test-echo-trailing-bin";
    /* -bin values are base64 on the grpc-dc wire: "q83v" is
       base64 for the bytes AB CD EF the official case sends. */
    static const char *TRAILER_VAL = "q83v";
    char what[128];
    size_t n = sizeof(interop_cases) / sizeof(interop_cases[0]);
    for (size_t ci = 0; ci < n; ci++) {
        const InteropCase *c = &interop_cases[ci];
        snprintf(what, sizeof(what), "interop %s", c->name);
        if (strcmp(c->kind, "EMPTY") == 0) {
            Empty req, resp;
            Empty_init(&req);
            grpcdc_status st =
                TestServiceClient_empty_call(client, &req, &resp, NULL, 0, 0);
            check(grpcdc_status_is_ok(st), what);
        } else if (strcmp(c->kind, "LARGE_UNARY") == 0) {
            SimpleRequest req;
            SimpleRequest_init(&req);
            req.response_type = PayloadType_COMPRESSABLE;
            req.response_size = c->resp_sizes[0];
            req.payload = ic_payload(c->req_sizes[0]);
            SimpleResponse resp;
            grpcdc_status st =
                TestServiceClient_unary_call(client, &req, &resp, NULL, 0, 0);
            check(grpcdc_status_is_ok(st), what);
            check(resp.payload && (int)resp.payload->body.len == c->resp_sizes[0],
                  what);
        } else if (strcmp(c->kind, "CLIENT_STREAMING") == 0) {
            StreamingInputCallRequest reqs[4];
            int want = 0;
            for (int i = 0; i < c->req_count; i++) {
                StreamingInputCallRequest_init(&reqs[i]);
                reqs[i].payload = ic_payload(c->req_sizes[i]);
                want += c->req_sizes[i];
            }
            StreamingInputCallResponse resp;
            grpcdc_status st = TestServiceClient_streaming_input_call(
                client, reqs, (size_t)c->req_count, &resp, NULL, 0, 0);
            check(grpcdc_status_is_ok(st), what);
            check(resp.aggregated_payload_size == want, what);
        } else if (strcmp(c->kind, "SERVER_STREAMING") == 0) {
            StreamingOutputCallRequest *reqs = ic_out_reqs(c);
            TestServiceStreamingOutputCallClient stream;
            grpcdc_status st = TestServiceClient_streaming_output_call(
                client, &reqs[0], &stream, NULL, 0, 0);
            check(grpcdc_status_is_ok(st), what);
            for (int i = 0; i < c->resp_count; i++) {
                StreamingOutputCallResponse one;
                grpcdc_status rst;
                int r = TestServiceStreamingOutputCallClient_recv(&stream, &one, &rst);
                check(r == 1 && one.payload &&
                          (int)one.payload->body.len == c->resp_sizes[i],
                      what);
            }
            StreamingOutputCallResponse extra;
            grpcdc_status rst;
            check(TestServiceStreamingOutputCallClient_recv(&stream, &extra, &rst) == 0,
                  what);
            TestServiceStreamingOutputCallClient_close(&stream);
            free(reqs);
        } else if (strcmp(c->kind, "PING_PONG") == 0) {
            StreamingOutputCallRequest *reqs =
                (StreamingOutputCallRequest *)calloc(4, sizeof(StreamingOutputCallRequest));
            for (int i = 0; i < c->req_count; i++) {
                StreamingOutputCallRequest_init(&reqs[i]);
                reqs[i].response_parameters =
                    (ResponseParameters *)calloc(1, sizeof(ResponseParameters));
                reqs[i].response_parameters_count = 1;
                ResponseParameters_init(&reqs[i].response_parameters[0]);
                reqs[i].response_parameters[0].size = c->resp_sizes[i];
                reqs[i].payload = ic_payload(c->req_sizes[i]);
            }
            TestServiceFullDuplexCallClient stream;
            grpcdc_status st = TestServiceClient_full_duplex_call(
                client, reqs, (size_t)c->req_count, &stream, NULL, 0, 0);
            check(grpcdc_status_is_ok(st), what);
            for (int i = 0; i < c->req_count; i++) {
                StreamingOutputCallResponse one;
                grpcdc_status rst;
                int r = TestServiceFullDuplexCallClient_recv(&stream, &one, &rst);
                check(r == 1 && one.payload &&
                          (int)one.payload->body.len == c->resp_sizes[i],
                      what);
            }
            StreamingOutputCallResponse extra;
            grpcdc_status rst;
            check(TestServiceFullDuplexCallClient_recv(&stream, &extra, &rst) == 0, what);
            TestServiceFullDuplexCallClient_close(&stream);
            free(reqs);
        } else if (strcmp(c->kind, "EMPTY_STREAM") == 0) {
            StreamingOutputCallRequest *reqs =
                (StreamingOutputCallRequest *)calloc(1, sizeof(StreamingOutputCallRequest));
            StreamingOutputCallRequest_init(&reqs[0]);
            TestServiceFullDuplexCallClient stream;
            grpcdc_status st = TestServiceClient_full_duplex_call(
                client, reqs, 0, &stream, NULL, 0, 0);
            check(grpcdc_status_is_ok(st), what);
            StreamingOutputCallResponse one;
            grpcdc_status rst;
            check(TestServiceFullDuplexCallClient_recv(&stream, &one, &rst) == 0, what);
            TestServiceFullDuplexCallClient_close(&stream);
            free(reqs);
        } else if (strcmp(c->kind, "CUSTOM_METADATA") == 0) {
            grpcdc_kv md[2] = {{INITIAL_KEY, INITIAL_VAL},
                               {TRAILER_KEY, TRAILER_VAL}};
            StreamingOutputCallRequest *reqs =
                (StreamingOutputCallRequest *)calloc(1, sizeof(StreamingOutputCallRequest));
            StreamingOutputCallRequest_init(&reqs[0]);
            reqs[0].response_parameters =
                (ResponseParameters *)calloc(1, sizeof(ResponseParameters));
            reqs[0].response_parameters_count = 1;
            ResponseParameters_init(&reqs[0].response_parameters[0]);
            reqs[0].response_parameters[0].size = 314159;
            TestServiceFullDuplexCallClient stream;
            grpcdc_status st = TestServiceClient_full_duplex_call(
                client, reqs, 1, &stream, md, 2, 0);
            check(grpcdc_status_is_ok(st), what);
            StreamingOutputCallResponse one;
            grpcdc_status rst;
            int r = TestServiceFullDuplexCallClient_recv(&stream, &one, &rst);
            check(r == 1 && one.payload && (int)one.payload->body.len == 314159, what);
            size_t hc = 0, tc = 0;
            const grpcdc_kv *headers = grpcdc_stream_headers(stream.raw, &hc);

            const char *iv = headers ? ic_kv_get(headers, hc, INITIAL_KEY) : NULL;
            check(iv && strcmp(iv, INITIAL_VAL) == 0, what);
            StreamingOutputCallResponse extra;
            check(TestServiceFullDuplexCallClient_recv(&stream, &extra, &rst) == 0, what);
            const grpcdc_kv *trailers = grpcdc_stream_trailers(stream.raw, &tc);
            const char *tv = trailers ? ic_kv_get(trailers, tc, TRAILER_KEY) : NULL;
            check(tv && strcmp(tv, TRAILER_VAL) == 0, what);
            TestServiceFullDuplexCallClient_close(&stream);
            free(reqs);
        } else if (strcmp(c->kind, "STATUS_UNARY") == 0 ||
                   strcmp(c->kind, "SPECIAL_STATUS") == 0) {
            SimpleRequest req;
            SimpleRequest_init(&req);
            req.response_status = (EchoStatus *)calloc(1, sizeof(EchoStatus));
            req.response_status->code = c->status_code;
            req.response_status->message = (char *)c->status_message;
            SimpleResponse resp;
            grpcdc_status st =
                TestServiceClient_unary_call(client, &req, &resp, NULL, 0, 0);
            check(st.code == c->status_code &&
                      strcmp(st.message, c->status_message) == 0,
                  what);
        } else if (strcmp(c->kind, "STATUS_DUPLEX") == 0) {
            StreamingOutputCallRequest req;
            StreamingOutputCallRequest_init(&req);
            req.response_status = (EchoStatus *)calloc(1, sizeof(EchoStatus));
            req.response_status->code = c->status_code;
            req.response_status->message = (char *)c->status_message;
            TestServiceFullDuplexCallClient stream;
            grpcdc_status st = TestServiceClient_full_duplex_call(
                client, &req, 1, &stream, NULL, 0, 0);
            check(grpcdc_status_is_ok(st), what);
            StreamingOutputCallResponse one;
            grpcdc_status rst;
            int r = TestServiceFullDuplexCallClient_recv(&stream, &one, &rst);
            check(r == -1 && rst.code == c->status_code &&
                      strcmp(rst.message, c->status_message) == 0,
                  what);
            TestServiceFullDuplexCallClient_close(&stream);
        } else if (strcmp(c->kind, "CANCEL_AFTER_BEGIN") == 0) {
            /* Begin a client-streaming call and cancel it before
               sending any request: the pending recv must report
               CANCELLED. */
            grpcdc_stream *raw = NULL;
            grpcdc_status st = grpcdc_channel_open(
                client->channel, "/grpc.testing.TestService/StreamingInputCall",
                NULL, 0, 0, NULL, 0, 0, &raw);
            check(grpcdc_status_is_ok(st), what);
            grpcdc_stream_cancel(raw);
            grpcdc_bytes out;
            grpcdc_status rst;
            int r = grpcdc_stream_recv(raw, &out, &rst);
            check(r == -1 && rst.code == c->status_code, what);
            grpcdc_stream_free(raw);
        } else if (strcmp(c->kind, "CANCEL_AFTER_FIRST") == 0) {
            /* Duplex call (no half-close): the server answers the
               one request, then waits for more input, so the cancel
               deterministically lands mid-call (same shape as the
               Python/JS suites). */
            StreamingOutputCallRequest req;
            StreamingOutputCallRequest_init(&req);
            req.response_parameters =
                (ResponseParameters *)calloc(1, sizeof(ResponseParameters));
            req.response_parameters_count = 1;
            ResponseParameters_init(&req.response_parameters[0]);
            req.response_parameters[0].size = c->resp_sizes[0];
            req.payload = ic_payload(1);
            grpcdc_stream *raw = NULL;
            grpcdc_status st = grpcdc_channel_open(
                client->channel, "/grpc.testing.TestService/FullDuplexCall",
                NULL, 0, 0, NULL, 0, 0, &raw);
            check(grpcdc_status_is_ok(st), what);
            MessagesPbBytes rb = StreamingOutputCallRequest_marshal(&req);
            st = grpcdc_stream_send(raw, rb.data, rb.len);
            free(rb.data);
            check(grpcdc_status_is_ok(st), what);
            grpcdc_bytes out;
            grpcdc_status rst;
            int r = grpcdc_stream_recv(raw, &out, &rst);
            check(r == 1, what);
            StreamingOutputCallResponse resp;
            StreamingOutputCallResponse_init(&resp);
            StreamingOutputCallResponse_unmarshal(&resp, out.data, out.len);
            grpcdc_bytes_free(&out);
            check(resp.payload &&
                      (int)resp.payload->body.len == c->resp_sizes[0],
                  what);
            grpcdc_stream_cancel(raw);
            r = grpcdc_stream_recv(raw, &out, &rst);
            check(r == -1 && rst.code == c->status_code, what);
            grpcdc_stream_free(raw);
        } else if (strcmp(c->kind, "TIMEOUT_SLEEPING") == 0) {
            StreamingOutputCallRequest req;
            StreamingOutputCallRequest_init(&req);
            req.response_parameters = (ResponseParameters *)calloc(
                4, sizeof(ResponseParameters));
            req.response_parameters_count = (size_t)c->resp_count;
            for (int j = 0; j < c->resp_count; j++) {
                ResponseParameters_init(&req.response_parameters[j]);
                req.response_parameters[j].size = c->resp_sizes[j];
                req.response_parameters[j].interval_us = 1000000;
            }
            req.payload = ic_payload(0);
            TestServiceStreamingOutputCallClient stream;
            grpcdc_status st = TestServiceClient_streaming_output_call(
                client, &req, &stream, NULL, 0, 100);
            check(grpcdc_status_is_ok(st), what);
            StreamingOutputCallResponse one;
            grpcdc_status rst;
            int r = TestServiceStreamingOutputCallClient_recv(&stream, &one, &rst);
            check(r == -1 && rst.code == c->status_code, what);
            TestServiceStreamingOutputCallClient_close(&stream);
        } else if (strcmp(c->kind, "UNIMPLEMENTED_METHOD") == 0) {
            Empty req, resp;
            Empty_init(&req);
            grpcdc_status st =
                TestServiceClient_unimplemented_call(client, &req, &resp, NULL, 0, 0);
            check(st.code == c->status_code, what);
        } else if (strcmp(c->kind, "UNIMPLEMENTED_SERVICE") == 0) {
            Empty req, resp;
            Empty_init(&req);
            grpcdc_status st = UnimplementedServiceClient_unimplemented_call(
                unimpl, &req, &resp, NULL, 0, 0);
            check(st.code == c->status_code, what);
        } else {
            check(0, what);
        }
        printf("interop case ok: %s\n", c->name);
    }
}

/* Compression rows (upstream client_compressed_unary,
   client_compressed_streaming, server_compressed_unary,
   server_compressed_streaming): the DataChannel wire is
   compression-free; the client declares grpc-encoding: gzip
   and the bridge gzips request messages on the HTTP/2 hop,
   decompressing responses the same way. */
static BoolValue *ic_true(void) {
    BoolValue *b = (BoolValue *)calloc(1, sizeof(BoolValue));
    BoolValue_init(b);
    b->value = true;
    return b;
}

static void run_compression_cases(TestServiceClient *client) {
    static const grpcdc_kv gzip_md[] = {{"grpc-encoding", "gzip"}};
    {
        SimpleRequest req;
        SimpleRequest_init(&req);
        req.response_size = 31415;
        req.payload = ic_payload(271828);
        req.expect_compressed = ic_true();
        SimpleResponse resp;
        grpcdc_status st = TestServiceClient_unary_call(
            client, &req, &resp, gzip_md, 1, 0);
        check(grpcdc_status_is_ok(st), "client_compressed_unary: status");
        check(resp.payload && (int)resp.payload->body.len == 31415,
              "client_compressed_unary: body");
        printf("interop case ok: client_compressed_unary\n");
    }
    {
        static const int sizes[] = {27182, 8, 1828, 45904};
        StreamingInputCallRequest reqs[4];
        int total = 0;
        for (int i = 0; i < 4; i++) {
            StreamingInputCallRequest_init(&reqs[i]);
            reqs[i].payload = ic_payload(sizes[i]);
            reqs[i].expect_compressed = ic_true();
            total += sizes[i];
        }
        StreamingInputCallResponse resp;
        grpcdc_status st = TestServiceClient_streaming_input_call(
            client, reqs, 4, &resp, gzip_md, 1, 0);
        check(grpcdc_status_is_ok(st), "client_compressed_streaming: status");
        check(resp.aggregated_payload_size == total,
              "client_compressed_streaming: aggregated");
        printf("interop case ok: client_compressed_streaming\n");
    }
    {
        SimpleRequest req;
        SimpleRequest_init(&req);
        req.response_size = 31415;
        req.payload = ic_payload(271828);
        req.response_compressed = ic_true();
        SimpleResponse resp;
        grpcdc_status st = TestServiceClient_unary_call(
            client, &req, &resp, NULL, 0, 0);
        check(grpcdc_status_is_ok(st), "server_compressed_unary: status");
        check(resp.payload && (int)resp.payload->body.len == 31415,
              "server_compressed_unary: body");
        printf("interop case ok: server_compressed_unary\n");
    }
    {
        static const int sizes[] = {31415, 9, 2653, 58979};
        StreamingOutputCallRequest req;
        StreamingOutputCallRequest_init(&req);
        req.response_parameters = (ResponseParameters *)calloc(
            4, sizeof(ResponseParameters));
        req.response_parameters_count = 4;
        for (int i = 0; i < 4; i++) {
            ResponseParameters_init(&req.response_parameters[i]);
            req.response_parameters[i].size = sizes[i];
            req.response_parameters[i].compressed = ic_true();
        }
        req.payload = ic_payload(0);
        TestServiceStreamingOutputCallClient stream;
        grpcdc_status st = TestServiceClient_streaming_output_call(
            client, &req, &stream, NULL, 0, 0);
        check(grpcdc_status_is_ok(st), "server_compressed_streaming: status");
        for (int i = 0; i < 4; i++) {
            StreamingOutputCallResponse one;
            grpcdc_status rst;
            int r = TestServiceStreamingOutputCallClient_recv(&stream, &one, &rst);
            check(r == 1 && one.payload &&
                      (int)one.payload->body.len == sizes[i],
                  "server_compressed_streaming: body");
        }
        TestServiceStreamingOutputCallClient_close(&stream);
        printf("interop case ok: server_compressed_streaming\n");
    }
}

/* ORCA rows (upstream orca_per_rpc / orca_oob): per-RPC the
   report returns as the serialized OrcaLoadReport in the
   endpoint-load-metrics-bin trailer (base64 -bin value); OOB the
   value fed through FullDuplexCall comes back on the
   OpenRcaService StreamCoreMetrics stream. */
static int ic_b64_val(int ch) {
    if (ch >= 'A' && ch <= 'Z') return ch - 'A';
    if (ch >= 'a' && ch <= 'z') return ch - 'a' + 26;
    if (ch >= '0' && ch <= '9') return ch - '0' + 52;
    if (ch == '+') return 62;
    if (ch == '/') return 63;
    return -1;
}

static size_t ic_b64_decode(const char *in, uint8_t *out) {
    size_t n = 0;
    int acc = 0, bits = 0;
    for (const char *p = in; *p; p++) {
        if (*p == '=') break;
        int v = ic_b64_val((uint8_t)*p);
        if (v < 0) continue;
        acc = (acc << 6) | v;
        bits += 6;
        if (bits >= 8) {
            bits -= 8;
            out[n++] = (uint8_t)((acc >> bits) & 0xff);
        }
    }
    return n;
}

static void run_orca_cases(TestServiceClient *client,
                           grpcdc_channel *channel) {
    /* orca_per_rpc */
    SimpleRequest req;
    SimpleRequest_init(&req);
    req.orca_per_query_report =
        (TestOrcaReport *)calloc(1, sizeof(TestOrcaReport));
    TestOrcaReport_init(req.orca_per_query_report);
    req.orca_per_query_report->cpu_utilization = 0.8210;
    req.orca_per_query_report->memory_utilization = 0.5847;
    req.orca_per_query_report->request_cost =
        (TestOrcaReport_RequestCostEntry *)calloc(
            1, sizeof(TestOrcaReport_RequestCostEntry));
    req.orca_per_query_report->request_cost_count = 1;
    req.orca_per_query_report->request_cost[0].key = (char *)"cost";
    req.orca_per_query_report->request_cost[0].value = 3456.32;
    req.orca_per_query_report->utilization =
        (TestOrcaReport_UtilizationEntry *)calloc(
            1, sizeof(TestOrcaReport_UtilizationEntry));
    req.orca_per_query_report->utilization_count = 1;
    req.orca_per_query_report->utilization[0].key = (char *)"util";
    req.orca_per_query_report->utilization[0].value = 0.30499;
    MessagesPbBytes rb = SimpleRequest_marshal(&req);
    grpcdc_stream *raw = NULL;
    grpcdc_status st = grpcdc_channel_open(
        channel, "/grpc.testing.TestService/UnaryCall", rb.data, rb.len, 1,
        NULL, 0, 0, &raw);
    free(rb.data);
    check(grpcdc_status_is_ok(st), "orca_per_rpc: open");
    grpcdc_bytes out;
    grpcdc_status rst;
    int r = grpcdc_stream_recv(raw, &out, &rst);
    check(r == 1, "orca_per_rpc: response");
    grpcdc_bytes_free(&out);
    r = grpcdc_stream_recv(raw, &out, &rst);
    check(r == 0, "orca_per_rpc: end");
    size_t tc = 0;
    const grpcdc_kv *trailers = grpcdc_stream_trailers(raw, &tc);
    const char *encoded = trailers ? ic_kv_get(trailers, tc, "endpoint-load-metrics-bin") : NULL;
    check(encoded != NULL, "orca_per_rpc: no endpoint-load-metrics-bin trailer");
    uint8_t raw_report[4096];
    size_t raw_len = ic_b64_decode(encoded, raw_report);
    OrcaLoadReport report;
    OrcaLoadReport_init(&report);
    OrcaLoadReport_unmarshal(&report, raw_report, raw_len);
    int cost_ok = 0, util_ok = 0;
    for (size_t i = 0; i < report.request_cost_count; i++) {
        if (strcmp(report.request_cost[i].key, "cost") == 0 &&
            report.request_cost[i].value == 3456.32) cost_ok = 1;
    }
    for (size_t i = 0; i < report.utilization_count; i++) {
        if (strcmp(report.utilization[i].key, "util") == 0 &&
            report.utilization[i].value == 0.30499) util_ok = 1;
    }
    check(report.cpu_utilization == 0.8210 &&
              report.mem_utilization == 0.5847 && cost_ok && util_ok,
          "orca_per_rpc: report mismatch");
    grpcdc_stream_free(raw);
    printf("interop case ok: orca_per_rpc\n");

    /* orca_oob */
    StreamingOutputCallRequest feed_req;
    StreamingOutputCallRequest_init(&feed_req);
    feed_req.orca_oob_report =
        (TestOrcaReport *)calloc(1, sizeof(TestOrcaReport));
    TestOrcaReport_init(feed_req.orca_oob_report);
    feed_req.orca_oob_report->cpu_utilization = 0.9;
    feed_req.orca_oob_report->memory_utilization = 0.85;
    feed_req.orca_oob_report->utilization =
        (TestOrcaReport_UtilizationEntry *)calloc(
            1, sizeof(TestOrcaReport_UtilizationEntry));
    feed_req.orca_oob_report->utilization_count = 1;
    feed_req.orca_oob_report->utilization[0].key = (char *)"util";
    feed_req.orca_oob_report->utilization[0].value = 0.5;
    TestServiceFullDuplexCallClient feed;
    st = TestServiceClient_full_duplex_call(client, &feed_req, 1, &feed,
                                            NULL, 0, 0);
    check(grpcdc_status_is_ok(st), "orca_oob: feed open");
    StreamingOutputCallResponse one;
    grpcdc_status fst;
    r = TestServiceFullDuplexCallClient_recv(&feed, &one, &fst);
    check(r == 0, "orca_oob: feed end");
    TestServiceFullDuplexCallClient_close(&feed);
    OpenRcaServiceClient orca;
    orca.channel = channel;
    OrcaLoadReportRequest metrics_req;
    OrcaLoadReportRequest_init(&metrics_req);
    OpenRcaServiceStreamCoreMetricsClient metrics;
    st = OpenRcaServiceClient_stream_core_metrics(&orca, &metrics_req,
                                                  &metrics, NULL, 0, 30000);
    check(grpcdc_status_is_ok(st), "orca_oob: metrics open");
    int matched = 0;
    for (int i = 0; i < 30 && !matched; i++) {
        OrcaLoadReport got;
        grpcdc_status mst;
        int mr = OpenRcaServiceStreamCoreMetricsClient_recv(&metrics, &got, &mst);
        if (mr != 1) break;
        int uok = 0;
        for (size_t j = 0; j < got.utilization_count; j++) {
            if (strcmp(got.utilization[j].key, "util") == 0 &&
                got.utilization[j].value == 0.5) uok = 1;
        }
        matched = got.cpu_utilization == 0.9 &&
                  got.mem_utilization == 0.85 && uok;
    }
    check(matched, "orca_oob: no matching OOB report");
    OpenRcaServiceStreamCoreMetricsClient_close(&metrics);
    printf("interop case ok: orca_oob\n");
}

static void test_interop_oracle(void) {
    char root[1024];
    find_root(root, sizeof(root));
    char bridge[1024];
    snprintf(bridge, sizeof(bridge), "%s/oracle/bridge.mjs", root);
    char server_bin[1024];
    snprintf(server_bin, sizeof(server_bin), "%s/oracle/go-interop/interop-server",
             root);
    if (!file_exists(server_bin)) {
        printf("TestInteropOracle SKIP (go interop server not built)\n");
        return;
    }
    int port = free_port();
    char port_str[16];
    snprintf(port_str, sizeof(port_str), "%d", port);
    char *server_argv[] = {server_bin, "-port", port_str, NULL};
    child_proc server = {-1, -1, -1, -1};
    child_proc br = {-1, -1, -1, -1};
    if (spawn_child(server_argv, &server) != 0) {
        kill_child(&server);
        printf("TestInteropOracle SKIP (interop server did not start)\n");
        return;
    }
    int ready = 0;
    for (int i = 0; i < 300 && !ready; i++) {
        int s = socket(AF_INET, SOCK_STREAM, 0);
        struct sockaddr_in addr;
        memset(&addr, 0, sizeof(addr));
        addr.sin_family = AF_INET;
        addr.sin_port = htons((uint16_t)port);
        addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
        if (connect(s, (struct sockaddr *)&addr, sizeof(addr)) == 0) ready = 1;
        close(s);
        if (!ready) usleep(100 * 1000);
    }
    if (!ready) {
        kill_child(&server);
        printf("TestInteropOracle SKIP (interop server did not start)\n");
        return;
    }
    char grpc_addr[64];
    snprintf(grpc_addr, sizeof(grpc_addr), "127.0.0.1:%d", port);
    char *bridge_argv[] = {"node", bridge, "dc-to-http2", "--grpc",
                           grpc_addr, NULL};
    if (spawn_child(bridge_argv, &br) != 0) {
        kill_child(&server);
        printf("TestInteropOracle SKIP (bridge did not start)\n");
        return;
    }
    stdio_transport transport;
    stdio_transport_init(&transport, br.stdout_fd, br.stdin_fd);
    grpcdc_transport iface = stdio_transport_iface(&transport);
    grpcdc_channel channel;
    grpcdc_channel_init(&channel, &iface);
    TestServiceClient client;
    client.channel = &channel;
    UnimplementedServiceClient unimpl;
    unimpl.channel = &channel;
    run_interop_cases(&client, &unimpl);
    run_compression_cases(&client);
    run_orca_cases(&client, &channel);
    kill_child(&br);
    kill_child(&server);
    printf("TestInteropOracle OK\n");
}

/* Field value or the proto3 default (zero fields are omitted on
   the wire, so absence reads as 0). */
static uint64_t dyn_varint_or(const grpcdc_dyn_msg *msg,
                              const grpcdc_dyn_field *field, uint64_t dflt) {
    uint64_t v;
    return grpcdc_dyn_msg_get_varint(msg, field, &v) ? v : dflt;
}

/* The generated oracle scenario table through the dynamic
   (descriptor-driven) client: same Echo expectation rules as
   run_oracle_cases, but every message is a generic field map and
   every path/field number comes from the parsed descriptors. */
static void run_oracle_cases_dynamic(grpcdc_channel *channel,
                                     const grpcdc_dyn_schema *schema) {
    const grpcdc_dyn_service *svc =
        grpcdc_dyn_find_service(schema, ".echo.Echo");
    check(svc != NULL, "dynamic: echo service in schema");
    const grpcdc_dyn_message *req_desc =
        grpcdc_dyn_find_message(schema, ".echo.EchoRequest");
    const grpcdc_dyn_message *resp_desc =
        grpcdc_dyn_find_message(schema, ".echo.EchoResponse");
    check(req_desc && resp_desc, "dynamic: echo messages in schema");
    const grpcdc_dyn_field *f_message =
        grpcdc_dyn_find_field(req_desc, "message");
    const grpcdc_dyn_field *f_count = grpcdc_dyn_find_field(req_desc, "count");
    const grpcdc_dyn_field *f_resp_message =
        grpcdc_dyn_find_field(resp_desc, "message");
    const grpcdc_dyn_field *f_resp_index =
        grpcdc_dyn_find_field(resp_desc, "index");
    check(f_message && f_count && f_resp_message && f_resp_index,
          "dynamic: echo fields in schema");

    for (size_t ci = 0; ci < oracle_cases_count; ci++) {
        const oracle_case *c = &oracle_cases[ci];
        if (strcmp(c->kind, "UNARY") == 0) {
            const grpcdc_dyn_method *m = grpcdc_dyn_find_method(svc, "Unary");
            char *path = grpcdc_dyn_method_path(svc, m);
            const char *msg = unmsg(c->messages[0]);
            grpcdc_dyn_msg req, resp;
            grpcdc_dyn_msg_init(&req);
            grpcdc_dyn_msg_init(&resp);
            grpcdc_dyn_msg_set_string(&req, f_message, msg);
            grpcdc_status st = grpcdc_dyn_unary(channel, path, &req, &resp);
            free(path);
            if (c->expect_status >= 0) {
                check(st.code == c->expect_status, "dynamic UNARY: status");
            } else {
                check(grpcdc_status_is_ok(st), "dynamic UNARY: status");
                char *got = NULL;
                uint64_t index = 99;
                char want[256];
                snprintf(want, sizeof(want), "echo: %s", msg);
                check(grpcdc_dyn_msg_get_string(&resp, f_resp_message, &got) &&
                          strcmp(got, want) == 0,
                      "dynamic UNARY: response");
                check(dyn_varint_or(&resp, f_resp_index, 0) == 0,
                      "dynamic UNARY: index");
                grpcdc_dyn_string_free(got);
            }
            grpcdc_dyn_msg_free(&req);
            grpcdc_dyn_msg_free(&resp);
        } else if (strcmp(c->kind, "SERVER_STREAM") == 0) {
            const grpcdc_dyn_method *m =
                grpcdc_dyn_find_method(svc, "ServerStream");
            char *path = grpcdc_dyn_method_path(svc, m);
            grpcdc_dyn_msg req;
            grpcdc_dyn_msg_init(&req);
            grpcdc_dyn_msg_set_string(&req, f_message, unmsg(c->messages[0]));
            grpcdc_dyn_msg_set_varint(&req, f_count, (uint64_t)c->count);
            grpcdc_bytes rb = grpcdc_dyn_msg_encode(&req);
            grpcdc_dyn_msg_free(&req);
            grpcdc_stream *stream = NULL;
            grpcdc_status st = grpcdc_channel_open(
                channel, path, rb.data, rb.len, 1, NULL, 0, 0, &stream);
            free(rb.data);
            free(path);
            check(grpcdc_status_is_ok(st), "dynamic SERVER_STREAM: open");
            int got = 0;
            while (1) {
                grpcdc_dyn_msg resp;
                grpcdc_dyn_msg_init(&resp);
                grpcdc_status rst;
                int r = grpcdc_dyn_stream_recv(stream, &resp, &rst);
                if (r == 0) {
                    grpcdc_dyn_msg_free(&resp);
                    break;
                }
                char *text = NULL;
                uint64_t index = 99;
                check(r == 1, "dynamic SERVER_STREAM: recv");
                check(grpcdc_dyn_msg_get_string(&resp, f_resp_message,
                                                &text) &&
                          strcmp(text, unmsg(c->messages[0])) == 0,
                      "dynamic SERVER_STREAM: response");
                check(dyn_varint_or(&resp, f_resp_index, 0) ==
                          (uint64_t)got,
                      "dynamic SERVER_STREAM: index");
                grpcdc_dyn_string_free(text);
                grpcdc_dyn_msg_free(&resp);
                got++;
            }
            check(got == c->count, "dynamic SERVER_STREAM: count");
            grpcdc_stream_free(stream);
        } else if (strcmp(c->kind, "CLIENT_STREAM") == 0 ||
                   strcmp(c->kind, "BIDI") == 0) {
            int is_bidi = strcmp(c->kind, "BIDI") == 0;
            const grpcdc_dyn_method *m = grpcdc_dyn_find_method(
                svc, is_bidi ? "Bidi" : "ClientStream");
            char *path = grpcdc_dyn_method_path(svc, m);
            grpcdc_stream *stream = NULL;
            grpcdc_status st =
                grpcdc_dyn_open(channel, path, NULL, 0, &stream);
            free(path);
            check(grpcdc_status_is_ok(st), "dynamic stream: open");
            for (size_t i = 0; i < c->messages_count; i++) {
                grpcdc_dyn_msg req;
                grpcdc_dyn_msg_init(&req);
                grpcdc_dyn_msg_set_string(&req, f_message,
                                          unmsg(c->messages[i]));
                st = grpcdc_dyn_stream_send(stream, &req);
                grpcdc_dyn_msg_free(&req);
                check(grpcdc_status_is_ok(st), "dynamic stream: send");
            }
            st = grpcdc_stream_close_send(stream);
            check(grpcdc_status_is_ok(st), "dynamic stream: half-close");
            if (is_bidi) {
                for (size_t i = 0; i < c->messages_count; i++) {
                    grpcdc_dyn_msg resp;
                    grpcdc_dyn_msg_init(&resp);
                    grpcdc_status rst;
                    int r = grpcdc_dyn_stream_recv(stream, &resp, &rst);
                    char *text = NULL;
                    uint64_t index = 99;
                    check(r == 1, "dynamic BIDI: recv");
                    check(grpcdc_dyn_msg_get_string(&resp, f_resp_message,
                                                    &text) &&
                              strcmp(text, unmsg(c->messages[i])) == 0,
                          "dynamic BIDI: echo");
                    check(dyn_varint_or(&resp, f_resp_index, 0) ==
                              (uint64_t)i,
                          "dynamic BIDI: index");
                    grpcdc_dyn_string_free(text);
                    grpcdc_dyn_msg_free(&resp);
                }
            } else {
                char want[512] = "";
                for (size_t i = 0; i < c->messages_count; i++) {
                    if (i) strcat(want, "+");
                    strcat(want, unmsg(c->messages[i]));
                }
                grpcdc_dyn_msg resp;
                grpcdc_dyn_msg_init(&resp);
                grpcdc_status rst;
                int r = grpcdc_dyn_stream_recv(stream, &resp, &rst);
                char *text = NULL;
                uint64_t index = 99;
                check(r == 1, "dynamic CLIENT_STREAM: recv");
                check(grpcdc_dyn_msg_get_string(&resp, f_resp_message,
                                                &text) &&
                          strcmp(text, want) == 0,
                      "dynamic CLIENT_STREAM: response");
                check(dyn_varint_or(&resp, f_resp_index, 0) ==
                          (uint64_t)c->messages_count,
                      "dynamic CLIENT_STREAM: index");
                grpcdc_dyn_string_free(text);
                grpcdc_dyn_msg_free(&resp);
            }
            {
                grpcdc_dyn_msg extra;
                grpcdc_dyn_msg_init(&extra);
                grpcdc_status rst;
                int r = grpcdc_dyn_stream_recv(stream, &extra, &rst);
                grpcdc_dyn_msg_free(&extra);
                check(r == 0, "dynamic stream: end");
            }
            grpcdc_stream_free(stream);
        }
    }
}

/* Run one official interop client process; fails the suite on
   nonzero exit or missing success marker. */
static void run_interop_client(char *const argv[], const char *marker) {
    child_proc ch = {-1, -1, -1, -1};
    check(spawn_child(argv, &ch) == 0, "client spawn");
    close(ch.stdin_fd);
    ch.stdin_fd = -1;
    char out_buf[65536];
    char err_buf[65536];
    /* Drain stdout and stderr concurrently; a sequential drain
       deadlocks when the child blocks writing the stream nobody
       is reading (e.g. goroutine dumps from the Go client). */
    drain_job out_job = {ch.stdout_fd, out_buf, sizeof(out_buf)};
    drain_job err_job = {ch.stderr_fd, err_buf, sizeof(err_buf)};
    pthread_t out_thread, err_thread;
    int have_out = pthread_create(&out_thread, NULL, drain_main, &out_job) == 0;
    int have_err = pthread_create(&err_thread, NULL, drain_main, &err_job) == 0;
    if (!have_out) drain_fd(ch.stdout_fd, out_buf, sizeof(out_buf));
    if (!have_err) drain_fd(ch.stderr_fd, err_buf, sizeof(err_buf));
    int code = wait_exit(&ch, 120000);
    if (code != 0) {
        // Keep the pipe ends open so the capture below shows
        // what the client actually said.
        fprintf(stderr, "interop client %s exited %d; output follows\n",
                argv[0], code);
    }
    if (have_out) pthread_join(out_thread, NULL);
    if (have_err) pthread_join(err_thread, NULL);
    if (code != 0) {
        fprintf(stderr, "--- client stdout ---\n%s\n--- client stderr ---\n%s\n",
                out_buf, err_buf);
    }
    check(code == 0, "interop client exit");
    if (marker) check(strstr(out_buf, marker) || strstr(err_buf, marker),
                      "interop client marker");
    kill_child(&ch);
}

/* Interop oracle, Direction B: the OFFICIAL interop clients
   (grpc-java TestServiceClient, grpc-go interop-client) run the
   canonical cases against the generated C TestService server
   (examples/interop_server_stdio), reached over HTTP/2 through
   oracle/bridge.mjs http2-to-dc. Skips when an oracle binary or
   Node is unavailable. Mirrors
   java/tests/TestInteropServerOracle.java. */
static void test_interop_server_oracle(void) {
    static const char *cases[] = {
        "empty_unary", "large_unary", "client_streaming",
        "server_streaming", "ping_pong", "empty_stream",
        "custom_metadata", "status_code_and_message",
        "special_status_message", "unimplemented_method",
        "unimplemented_service", "cancel_after_begin",
        "cancel_after_first_response", "timeout_on_sleeping_server",
    };
    static const char *java_only[] = {
        "cacheable_unary", "client_compressed_unary",
        "client_compressed_streaming", "server_compressed_unary",
        "server_compressed_streaming",
    };
    static const char *go_only[] = {"orca_per_rpc"};
    char root[1024];
    find_root(root, sizeof(root));
    char cp[8192];
    if (!java_classpath(root, cp, sizeof(cp))) {
        printf("TestInteropServerOracle SKIP (java oracle not built)\n");
        return;
    }
    char server_bin[1024];
    snprintf(server_bin, sizeof(server_bin), "%s/c/build/interop_server_stdio", root);
    if (!file_exists(server_bin)) {
        printf("TestInteropServerOracle SKIP (c server not built)\n");
        return;
    }
    int port = free_port();
    char port_str[16];
    snprintf(port_str, sizeof(port_str), "%d", port);
    char bridge_path[1024];
    snprintf(bridge_path, sizeof(bridge_path), "%s/oracle/bridge.mjs", root);
    char *bridge_argv[] = {"node", bridge_path, "http2-to-dc", "--port",
                           port_str, "--target-cmd", server_bin, NULL};
    child_proc bridge = {-1, -1, -1, -1};
    if (spawn_child(bridge_argv, &bridge) != 0 ||
        !wait_for_text(bridge.stderr_fd, "listening", 60000, NULL, 0)) {
        kill_child(&bridge);
        printf("TestInteropServerOracle SKIP (bridge did not start)\n");
        return;
    }
    char host_arg[64], port_arg[64], case_arg[96], tls_arg[32];
    snprintf(host_arg, sizeof(host_arg), "--server_host=127.0.0.1");
    snprintf(port_arg, sizeof(port_arg), "--server_port=%d", port);
    snprintf(tls_arg, sizeof(tls_arg), "--use_tls=false");
    for (size_t ci = 0; ci < sizeof(cases) / sizeof(cases[0]) + sizeof(java_only) / sizeof(java_only[0]); ci++) {
        const char *test_case = ci < sizeof(cases) / sizeof(cases[0])
                                    ? cases[ci]
                                    : java_only[ci - sizeof(cases) / sizeof(cases[0])];
        snprintf(case_arg, sizeof(case_arg), "--test_case=%s", test_case);
        char *argv[] = {"java", "-cp", cp,
                        "io.grpc.testing.integration.TestServiceClient",
                        host_arg, port_arg, case_arg, tls_arg, NULL};
        run_interop_client(argv, "Test completed.");
        printf("interop B case ok: %s (java client)\n", test_case);
    }
    char go_client[1024];
    snprintf(go_client, sizeof(go_client), "%s/oracle/go-interop/interop-client", root);
    if (!file_exists(go_client)) {
        printf("TestInteropServerOracle GO SKIP (go client not built)\n");
    } else {
        for (size_t ci = 0; ci < sizeof(cases) / sizeof(cases[0]) + sizeof(go_only) / sizeof(go_only[0]); ci++) {
            const char *test_case = ci < sizeof(cases) / sizeof(cases[0])
                                        ? cases[ci]
                                        : go_only[ci - sizeof(cases) / sizeof(cases[0])];
            if (strcmp(test_case, "orca_per_rpc") == 0) {
                /* The ORCA cases run under the
                   test_backend_metrics_load_balancer policy, which
                   keeps a background OOB watch stream open; the
                   generated C server serves one stream at a time,
                   so the watch starves the case's UnaryCall and the
                   Go client retries the watch (EOF spam) without
                   bound. Out of model for this runtime; per-RPC
                   ORCA is covered the other direction by
                   TestInteropOracle against the Java server. */
                printf("interop B case SKIP: orca_per_rpc (go client; generated C server is single-stream, ORCA load balancer needs a concurrent OOB watch stream)\n");
                continue;
            }
            if (strncmp(test_case, "orca", 4) == 0) {
                char *argv[] = {go_client, "-server_host", "127.0.0.1",
                                "-server_port", port_str, "-test_case",
                                (char *)test_case, "-service_config_json",
                                "{ \"loadBalancingConfig\": [{ \"test_backend_metrics_load_balancer\": {} }]}",
                                NULL};
                run_interop_client(argv, NULL);
            } else {
                char *argv[] = {go_client, "-server_host", "127.0.0.1",
                                "-server_port", port_str, "-test_case",
                                (char *)test_case, NULL};
                run_interop_client(argv, NULL);
            }
            printf("interop B case ok: %s (go client)\n", test_case);
        }
        /* orca_oob holds a FullDuplexCall open while issuing a
           UnaryCall and an OOB stream on the same connection;
           the generated C server serves one stream at a time,
           so that case is out of model for this runtime. */
        printf("interop B case SKIP: orca_oob (go client; generated C server is single-stream, ORCA OOB needs concurrent streams)\n");
    }
    kill_child(&bridge);
    printf("TestInteropServerOracle OK\n");
}

/* Dynamic (descriptor-driven) runtime: schemas consumed as data at
   runtime, no generated stubs. Loopback plus the official
   grpc-java oracle direction A. */
static void test_dynamic(void) {
    char root[1024];
    find_root(root, sizeof(root));
    char fixture[1024];
    snprintf(fixture, sizeof(fixture), "%s/fixtures/echo_descriptor_set.bin",
             root);
    FILE *f = fopen(fixture, "rb");
    if (!f) {
        printf("TestDynamic SKIP (descriptor fixture missing)\n");
        return;
    }
    fseek(f, 0, SEEK_END);
    long size = ftell(f);
    fseek(f, 0, SEEK_SET);
    uint8_t *data = (uint8_t *)malloc(size > 0 ? (size_t)size : 1);
    check(fread(data, 1, (size_t)size, f) == (size_t)size,
          "dynamic: read fixture");
    fclose(f);
    grpcdc_dyn_schema *schema = grpcdc_dyn_schema_parse(data, (size_t)size);
    free(data);
    check(schema != NULL, "dynamic: schema parses");

    /* Generic codec + unknown-field retention round trip. */
    static const uint8_t payload[] = {0x0a, 0x02, 0x68, 0x69, 0x10, 0x02,
                                      0x98, 0x06, 0x2a, 0xa2, 0x06, 0x01,
                                      0x78};
    grpcdc_dyn_msg decoded;
    grpcdc_dyn_msg_init(&decoded);
    check(grpcdc_dyn_msg_decode(&decoded, payload, sizeof(payload)),
          "dynamic: decode payload");
    check(decoded.count == 4, "dynamic: unknown fields retained");
    grpcdc_bytes reencoded = grpcdc_dyn_msg_encode(&decoded);
    check(reencoded.len == sizeof(payload) &&
              memcmp(reencoded.data, payload, sizeof(payload)) == 0,
          "dynamic: re-encode identical");
    free(reencoded.data);
    grpcdc_dyn_msg_free(&decoded);

    /* Loopback: dynamic client against the typed C server. */
    {
        grpcdc_memory_pair *pair = grpcdc_memory_pair_new();
        grpcdc_transport a, b;
        grpcdc_memory_pair_transports(pair, &a, &b);
        server_job job = {&b};
        pthread_t thread;
        check(pthread_create(&thread, NULL, server_main, &job) == 0,
              "dynamic server thread");
        grpcdc_channel channel;
        grpcdc_channel_init(&channel, &a);
        run_oracle_cases_dynamic(&channel, schema);
    }

    /* Oracle direction A: dynamic client -> bridge -> official. */
    char cp[8192];
    if (!java_classpath(root, cp, sizeof(cp))) {
        printf("TestDynamic oracle SKIP (java oracle not built)\n");
    } else {
        oracle_dir_a oa;
        if (!oracle_dir_a_start(root, cp, &oa)) {
            printf("TestDynamic oracle SKIP (oracle did not start)\n");
        } else {
            run_oracle_cases_dynamic(&oa.channel, schema);
            oracle_dir_a_stop(&oa);
        }
    }
    grpcdc_dyn_schema_free(schema);
    printf("dynamic tests passed\n");
}
#endif /* GRPCDC_POSIX */

#ifdef GRPCDC_POSIX
typedef struct {
    grpcdc_sidecar *sidecar;
    grpcdc_transport transport;
} sidecar_server_job;

static void *sidecar_server_main(void *arg) {
    sidecar_server_job *job = (sidecar_server_job *)arg;
    grpcdc_server *server = grpcdc_server_new();
    EchoServer_register(server, &echo_server_impl);
    grpcdc_server_serve(server, &job->transport);
    grpcdc_server_free(server);
    return NULL;
}

/* gRPC over WebRTC-Direct via the Rust sidecar, C to C: two
   direct_sidecar processes own the WebRTC stack; the C server
   and client only speak length-prefixed TCP to their local
   sidecar (grpcdc_sidecar). */
static void test_sidecar(void) {
    char root[1024];
    find_root(root, sizeof(root));
    char bin[1024];
    snprintf(bin, sizeof(bin), "%s/webrtc/rust/target/debug/examples/direct_sidecar", root);
    if (!file_exists(bin)) {
        char cmd[1200];
        snprintf(cmd, sizeof(cmd), "cd %s/webrtc/rust && cargo build --example direct_sidecar", root);
        check(system(cmd) == 0, "cargo build direct_sidecar");
    }

    int lang_port = free_port();
    int listen_fd = socket(AF_INET, SOCK_STREAM, 0);
    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    addr.sin_port = htons((uint16_t)lang_port);
    check(bind(listen_fd, (struct sockaddr *)&addr, sizeof(addr)) == 0, "bind lang port");
    check(listen(listen_fd, 4) == 0, "listen lang port");

    sidecar_server_job job;
    char lang_arg[64];
    snprintf(lang_arg, sizeof(lang_arg), "127.0.0.1:%d", lang_port);
    char *listen_argv[] = {bin, "listen", "--udp", "127.0.0.1:0", "--tcp", lang_arg, NULL};
    child_proc listen_proc = {-1, -1, -1, -1};
    check(spawn_child(listen_argv, &listen_proc) == 0, "spawn listen sidecar");
    static char ma_sink[8192];
    check(wait_for_text(listen_proc.stdout_fd, "MULTIADDR", 60000, ma_sink, sizeof(ma_sink)),
          "listen sidecar multiaddr");
    char *multiaddr = strstr(ma_sink, "/ip");
    check(multiaddr != NULL, "multiaddr parse");
    char *nl = strchr(multiaddr, '\n');
    if (nl) *nl = 0;

    int client_port = free_port();
    char client_arg[64];
    snprintf(client_arg, sizeof(client_arg), "127.0.0.1:%d", client_port);
    char *dial_argv[] = {bin, "dial", "--multiaddr", multiaddr, "--tcp", client_arg, NULL};
    child_proc dial_proc = {-1, -1, -1, -1};
    check(spawn_child(dial_argv, &dial_proc) == 0, "spawn dial sidecar");
    check(wait_for_text(dial_proc.stdout_fd, "TCP", 60000, NULL, 0), "dial sidecar tcp");

    /* The dial sidecar only dials Direct after a language client
       connects to its TCP listener, so connect the client first:
       that triggers the Direct handshake, the listen sidecar then
       connects to lang_port, and the accept below unblocks. */
    grpcdc_sidecar *client_sidecar = grpcdc_sidecar_connect("127.0.0.1", (uint16_t)client_port);
    check(client_sidecar != NULL, "client sidecar connect");

    job.sidecar = NULL;
    pthread_t server_thread;
    int conn_fd = accept(listen_fd, NULL, NULL);
    check(conn_fd >= 0, "accept lang conn");
    job.sidecar = grpcdc_sidecar_from_fd(conn_fd);
    grpcdc_sidecar_transport(job.sidecar, &job.transport);
    check(pthread_create(&server_thread, NULL, sidecar_server_main, &job) == 0,
          "server thread");

    grpcdc_transport transport;
    grpcdc_sidecar_transport(client_sidecar, &transport);
    grpcdc_channel channel;
    grpcdc_channel_init(&channel, &transport);
    EchoClient client;
    client.channel = &channel;

    EchoRequest req;
    EchoRequest_init(&req);
    req.message = "hello";
    EchoResponse resp;
    grpcdc_status st = EchoClient_unary(&client, &req, &resp, NULL, 0, 0);
    check(grpcdc_status_is_ok(st), "sidecar unary status");
    check(strcmp(resp.message, "echo: hello") == 0, "sidecar unary body");

    req.message = "tick";
    req.count = 3;
    EchoServerStreamClient stream;
    st = EchoClient_server_stream(&client, &req, &stream, NULL, 0, 0);
    check(grpcdc_status_is_ok(st), "sidecar stream open");
    for (int i = 0; i < 3; i++) {
        EchoResponse tick;
        grpcdc_status rst;
        int r = EchoServerStreamClient_recv(&stream, &tick, &rst);
        check(r == 1 && tick.index == i, "sidecar stream tick");
    }
    {
        EchoResponse extra;
        grpcdc_status rst;
        check(EchoServerStreamClient_recv(&stream, &extra, &rst) == 0, "sidecar stream end");
    }
    EchoServerStreamClient_close(&stream);

    kill_child(&dial_proc);
    kill_child(&listen_proc);
    close(listen_fd);
    printf("TestSidecar OK\n");
}
#endif /* GRPCDC_POSIX */

/* Kafka proxy end-to-end: generated C client -> Rust
 * kafka_proxy (--tcp) -> Apache Kafka / Redpanda.
 *
 * Env-gated: set KAFKA_E2E_PROXY_ADDR=host:port of a running
 * kafka_proxy (see scripts/kafka-e2e.sh / `make test-kafka`).
 * Skipped otherwise, so the plain `make test-c` run stays
 * broker-free. */
#ifdef GRPCDC_POSIX
#include "grpcdc/kafka_grpc_dc.h"

static char *kafka_create_topic(KafkaClient *client, char *topic, size_t cap) {
    snprintf(topic, cap, "c-kafka-e2e-%lx-%x",
             (unsigned long)time(NULL), (unsigned int)getpid());
    NewTopic spec;
    NewTopic_init(&spec);
    spec.name = topic;
    spec.num_partitions = 1;
    spec.replication_factor = 1;
    CreateTopicsRequest req;
    CreateTopicsRequest_init(&req);
    req.topics = &spec;
    req.topics_count = 1;
    req.timeout_ms = 15000;
    CreateTopicsResponse created;
    grpcdc_status st = KafkaClient_create_topics(client, &req, &created, NULL, 0, 0);
    check(grpcdc_status_is_ok(st), "create topics rpc");
    check(created.results_count == 1 && created.results[0].error_code == 0,
          "create topic");
    for (int waited = 0;; waited += 250) {
        ListOffsetsRequest latest_req;
        ListOffsetsRequest_init(&latest_req);
        latest_req.topic = topic;
        latest_req.partition = 0;
        latest_req.timestamp = -1;
        ListOffsetsResponse latest;
        st = KafkaClient_list_offsets(client, &latest_req, &latest, NULL, 0, 0);
        check(grpcdc_status_is_ok(st), "list offsets rpc");
        if (latest.error_code == 0) return topic;
        check(waited < 15000, "topic not visible");
        usleep(250000);
    }
}

static void kafka_produce(KafkaClient *client, const char *topic,
                          const char **values, size_t count, int64_t *offsets) {
    for (size_t i = 0; i < count; i++) {
        char keybuf[64];
        snprintf(keybuf, sizeof(keybuf), "k-%s", values[i]);
        Record rec;
        Record_init(&rec);
        rec.key = KafkaPb_bytes_copy((const uint8_t *)keybuf, strlen(keybuf));
        rec.value = KafkaPb_bytes_copy((const uint8_t *)values[i], strlen(values[i]));
        ProduceRequest req;
        ProduceRequest_init(&req);
        req.topic = (char *)topic;
        req.partition = 0;
        req.records = &rec;
        req.records_count = 1;
        ProduceResponse resp;
        grpcdc_status st = KafkaClient_produce(client, &req, &resp, NULL, 0, 0);
        check(grpcdc_status_is_ok(st), "produce rpc");
        check(resp.error_code == 0, "produce error");
        offsets[i] = resp.base_offset;
        free(rec.key.data);
        free(rec.value.data);
    }
}

static size_t kafka_consume(KafkaClient *client, const char *topic,
                            int64_t offset, int32_t count,
                            FetchedRecord *out, size_t cap) {
    ConsumeRequest req;
    ConsumeRequest_init(&req);
    req.topic = (char *)topic;
    req.partition = 0;
    req.offset = offset;
    req.max_records = count;
    KafkaConsumeClient stream;
    grpcdc_status st = KafkaClient_consume(client, &req, &stream, NULL, 0, 0);
    check(grpcdc_status_is_ok(st), "consume rpc");
    size_t got = 0;
    while (got < (size_t)count) {
        ConsumeResponse chunk;
        grpcdc_status rst;
        int r = KafkaConsumeClient_recv(&stream, &chunk, &rst);
        check(r == 1, "consume recv");
        check(chunk.error_code == 0, "consume error");
        for (size_t i = 0; i < chunk.records_count && got < cap; i++) {
            out[got++] = chunk.records[i];
        }
    }
    KafkaConsumeClient_close(&stream);
    return got;
}

static void kafka_delete_topic(KafkaClient *client, char *topic) {
    char *topics[1] = { topic };
    DeleteTopicsRequest req;
    DeleteTopicsRequest_init(&req);
    req.topics = topics;
    req.topics_count = 1;
    DeleteTopicsResponse resp;
    KafkaClient_delete_topics(client, &req, &resp, NULL, 0, 0);
}

static void test_kafka_e2e(void) {
    const char *addr = getenv("KAFKA_E2E_PROXY_ADDR");
    if (addr == NULL || addr[0] == '\0') {
        printf("TestKafkaE2E SKIP (KAFKA_E2E_PROXY_ADDR not set)\n");
        return;
    }
    const char *sep = strrchr(addr, ':');
    check(sep != NULL, "proxy addr");
    char host[128];
    size_t host_len = (size_t)(sep - addr);
    check(host_len < sizeof(host), "proxy host");
    memcpy(host, addr, host_len);
    host[host_len] = '\0';
    uint16_t port = (uint16_t)atoi(sep + 1);

    grpcdc_sidecar *sidecar = grpcdc_sidecar_connect(host, port);
    check(sidecar != NULL, "sidecar connect");
    grpcdc_transport transport;
    grpcdc_sidecar_transport(sidecar, &transport);
    grpcdc_channel channel;
    grpcdc_channel_init(&channel, &transport);
    KafkaClient client;
    client.channel = &channel;

    char topic[96];
    {
        kafka_create_topic(&client, topic, sizeof(topic));
        const char *values[] = {"v0", "v1", "v2"};
        int64_t offsets[3];
        kafka_produce(&client, topic, values, 3, offsets);
        check(offsets[0] == 0 && offsets[1] == 1 && offsets[2] == 2,
              "roundtrip offsets");
        ListOffsetsRequest latest_req;
        ListOffsetsRequest_init(&latest_req);
        latest_req.topic = topic;
        latest_req.partition = 0;
        latest_req.timestamp = -1;
        ListOffsetsResponse latest;
        grpcdc_status st = KafkaClient_list_offsets(&client, &latest_req, &latest, NULL, 0, 0);
        check(grpcdc_status_is_ok(st) && latest.offset == 3 && latest.error_code == 0,
              "latest offset");
        FetchedRecord got[3];
        check(kafka_consume(&client, topic, 0, 3, got, 3) == 3, "roundtrip count");
        check(got[0].value.len == 2 && memcmp(got[0].value.data, "v0", 2) == 0 &&
              got[1].value.len == 2 && memcmp(got[1].value.data, "v1", 2) == 0 &&
              got[2].value.len == 2 && memcmp(got[2].value.data, "v2", 2) == 0,
              "roundtrip values");
        check(got[0].key.len == 4 && memcmp(got[0].key.data, "k-v0", 4) == 0,
              "roundtrip keys");
        kafka_delete_topic(&client, topic);
    }
    {
        kafka_create_topic(&client, topic, sizeof(topic));
        const char *values[] = {"seq-00", "seq-01", "seq-02", "seq-03", "seq-04",
                                "seq-05", "seq-06", "seq-07", "seq-08", "seq-09"};
        int64_t offsets[10];
        kafka_produce(&client, topic, values, 10, offsets);
        for (int i = 0; i < 10; i++) check(offsets[i] == i, "ordering offsets");
        FetchedRecord got[10];
        check(kafka_consume(&client, topic, 0, 10, got, 10) == 10, "ordering count");
        for (int i = 0; i < 10; i++) {
            check(got[i].value.len == strlen(values[i]) &&
                  memcmp(got[i].value.data, values[i], got[i].value.len) == 0,
                  "ordering values");
        }
        kafka_delete_topic(&client, topic);
    }
    {
        kafka_create_topic(&client, topic, sizeof(topic));
        const char *values[] = {"a", "b", "c", "d"};
        int64_t offsets[4];
        kafka_produce(&client, topic, values, 4, offsets);
        FetchedRecord first[2];
        check(kafka_consume(&client, topic, 0, 2, first, 2) == 2, "resume first count");
        check(first[0].value.len == 1 && first[0].value.data[0] == 'a' &&
              first[1].value.len == 1 && first[1].value.data[0] == 'b',
              "resume first");
        FetchedRecord rest[2];
        check(kafka_consume(&client, topic, 2, 2, rest, 2) == 2, "resume rest count");
        check(rest[0].value.len == 1 && rest[0].value.data[0] == 'c' &&
              rest[1].value.len == 1 && rest[1].value.data[0] == 'd',
              "resume rest");
        kafka_delete_topic(&client, topic);
    }
    printf("TestKafkaE2E OK\n");
}
#endif /* GRPCDC_POSIX */

int main(int argc, char **argv) {
    if (argc < 2) {
        fprintf(stderr,
                "usage: tests <TestCodec|TestEcho|TestPbMessages|TestBdd|"
                "TestOracle|TestDynamic>\n");
        return 2;
    }
    if (strcmp(argv[1], "TestBddSchemas") == 0) test_bdd_schemas();
    else if (strcmp(argv[1], "TestCodec") == 0) test_codec();
    else if (strcmp(argv[1], "TestEcho") == 0) test_echo();
    else if (strcmp(argv[1], "TestEventBus") == 0) test_eventbus();
    else if (strcmp(argv[1], "TestPbMessages") == 0) test_pb_messages();
    else if (strcmp(argv[1], "TestBdd") == 0) test_bdd();
    else if (strcmp(argv[1], "TestDynamic") == 0) {
#ifdef GRPCDC_POSIX
        test_dynamic();
#else
        printf("TestDynamic SKIP (POSIX only)\n");
#endif
    }
    else if (strcmp(argv[1], "TestSidecar") == 0) {
#ifdef GRPCDC_POSIX
        test_sidecar();
#else
        printf("TestSidecar SKIP (POSIX only)\n");
#endif
    }
    else if (strcmp(argv[1], "TestKafkaE2E") == 0) {
#ifdef GRPCDC_POSIX
        test_kafka_e2e();
#else
        printf("TestKafkaE2E SKIP (POSIX only)\n");
#endif
    }
    else if (strcmp(argv[1], "TestInteropOracle") == 0) {
#ifdef GRPCDC_POSIX
        test_interop_oracle();
#else
        printf("TestInteropOracle SKIP (POSIX only)\n");
#endif
    }
    else if (strcmp(argv[1], "TestOracle") == 0) {
#ifdef GRPCDC_POSIX
        test_oracle();
#else
        printf("TestOracle SKIP (POSIX only)\n");
#endif
    }
    else if (strcmp(argv[1], "TestInteropServerOracle") == 0) {
#ifdef GRPCDC_POSIX
        test_interop_server_oracle();
#else
        printf("TestInteropServerOracle SKIP (POSIX only)\n");
#endif
    }
    else {
        fprintf(stderr, "unknown test %s\n", argv[1]);
        return 2;
    }
    return 0;
}
