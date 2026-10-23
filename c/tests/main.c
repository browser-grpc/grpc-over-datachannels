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

static void check(int cond, const char *what) {
    if (!cond) {
        fprintf(stderr, "FAIL: %s\n", what);
        exit(1);
    }
}

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
   (racket/bdd-schemas.rkt). */
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
   stamped from racket/bdd-spec.rkt; prose in BDD.md) against a
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
        if (strcmp(c->kind, "unary") == 0) {
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
    else if (strcmp(argv[1], "TestOracle") == 0) {
#ifdef GRPCDC_POSIX
        test_oracle();
#else
        printf("TestOracle SKIP (POSIX only)\n");
#endif
    }
    else {
        fprintf(stderr, "unknown test %s\n", argv[1]);
        return 2;
    }
    return 0;
}
