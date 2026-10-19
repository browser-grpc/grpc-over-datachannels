/* Test driver for the C runtime and generated code.
   Usage: tests <TestCodec|TestEcho|TestPbMessages> */
#include <assert.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "../examples/echo_service_impl.h"
#include "features_messages.h"
#include "kitchen_messages.h"
#include "grpcdc/memory_transport.h"

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

int main(int argc, char **argv) {
    if (argc < 2) {
        fprintf(stderr, "usage: tests <TestCodec|TestEcho|TestPbMessages>\n");
        return 2;
    }
    if (strcmp(argv[1], "TestCodec") == 0) test_codec();
    else if (strcmp(argv[1], "TestEcho") == 0) test_echo();
    else if (strcmp(argv[1], "TestPbMessages") == 0) test_pb_messages();
    else {
        fprintf(stderr, "unknown test %s\n", argv[1]);
        return 2;
    }
    return 0;
}
