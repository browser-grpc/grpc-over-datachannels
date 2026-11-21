/* Struct-codec negotiation e2e: struct<->struct roundtrip,
   mismatch rejected UNIMPLEMENTED, plain client still works. */
#ifndef GRPCDC_TEST_STRUCT_CODEC_H
#define GRPCDC_TEST_STRUCT_CODEC_H

#ifdef GRPCDC_NO_STRUCT_CODEC
/* Cross builds (test-c-cross) have no Rust cdylib for the target:
   satisfy the struct FFI references in the generated headers with
   weak stubs and compile the negotiation test out. */
__attribute__((weak)) int grpcdc_struct_encode(const uint8_t *desc, size_t desc_len, const uint8_t *type_name, size_t type_len, const uint8_t *input, size_t input_len, uint8_t **out, size_t *out_len, char **err_out) {
    (void)desc; (void)desc_len; (void)type_name; (void)type_len; (void)input; (void)input_len; (void)out; (void)out_len; (void)err_out;
    return -1;
}
__attribute__((weak)) int grpcdc_struct_decode(const uint8_t *desc, size_t desc_len, const uint8_t *type_name, size_t type_len, const uint8_t *input, size_t input_len, uint8_t **out, size_t *out_len, char **err_out) {
    (void)desc; (void)desc_len; (void)type_name; (void)type_len; (void)input; (void)input_len; (void)out; (void)out_len; (void)err_out;
    return -1;
}
__attribute__((weak)) void grpcdc_struct_free(uint8_t *ptr, size_t len) { (void)ptr; (void)len; }
__attribute__((weak)) void grpcdc_struct_error_free(char *ptr) { (void)ptr; }
static void test_struct_codec(void) { printf("TestStructCodec SKIP (no struct codec for this target)\n"); }
#else

typedef struct {
    grpcdc_transport *transport;
    int struct_codec;
} struct_server_job;

static void *struct_server_main(void *arg) {
    struct_server_job *job = (struct_server_job *)arg;
    grpcdc_server *server = grpcdc_server_new();
    grpcdc_server_set_struct_codec(server, job->struct_codec != 0);
    EchoServer_register(server, &echo_server_impl);
    grpcdc_server_serve(server, job->transport);
    grpcdc_server_free(server);
    return NULL;
}

static EchoClient struct_setup(grpcdc_memory_pair *pair, grpcdc_channel *channel,
                               int client_struct, int server_struct) {
    grpcdc_transport a, b;
    grpcdc_memory_pair_transports(pair, &a, &b);
    struct_server_job *job = (struct_server_job *)malloc(sizeof(struct_server_job));
    job->transport = (grpcdc_transport *)malloc(sizeof(grpcdc_transport));
    *job->transport = b;
    job->struct_codec = server_struct;
    pthread_t thread;
    check(pthread_create(&thread, NULL, struct_server_main, job) == 0,
          "struct server thread");
    grpcdc_transport *ta = (grpcdc_transport *)malloc(sizeof(grpcdc_transport));
    *ta = a;
    grpcdc_channel_init(channel, ta);
    grpcdc_channel_set_struct_codec(channel, client_struct != 0);
    EchoClient client;
    client.channel = channel;
    return client;
}

static void test_struct_codec(void) {
    /* Struct client against struct server: all four shapes. */
    {
        grpcdc_memory_pair *pair = grpcdc_memory_pair_new();
        grpcdc_channel channel;
        EchoClient client = struct_setup(pair, &channel, 1, 1);

        EchoRequest req;
        EchoRequest_init(&req);
        req.message = "hello";
        EchoResponse resp;
        grpcdc_status st = EchoClient_unary(&client, &req, &resp, NULL, 0, 0);
        check(grpcdc_status_is_ok(st), "struct unary status");
        check(strcmp(resp.message, "echo: hello") == 0, "struct unary body");

        req.message = "tick";
        req.count = 3;
        EchoServerStreamClient stream;
        st = EchoClient_server_stream(&client, &req, &stream, NULL, 0, 0);
        check(grpcdc_status_is_ok(st), "struct server stream open");
        int n = 0;
        for (;;) {
            EchoResponse tick;
            grpcdc_status rst;
            int r = EchoServerStreamClient_recv(&stream, &tick, &rst);
            if (r == 0) break;
            check(r == 1, "struct server stream recv");
            n++;
        }
        check(n == 3, "struct server stream count");
        EchoServerStreamClient_close(&stream);

        EchoRequest parts[2];
        EchoRequest_init(&parts[0]);
        parts[0].message = "a";
        EchoRequest_init(&parts[1]);
        parts[1].message = "b";
        EchoResponse joined;
        st = EchoClient_client_stream(&client, parts, 2, &joined, NULL, 0, 0);
        check(grpcdc_status_is_ok(st), "struct client stream status");
        check(strcmp(joined.message, "a+b") == 0, "struct client stream body");

        EchoBidiClient bidi;
        st = EchoClient_bidi(&client, parts, 2, &bidi, NULL, 0, 0);
        check(grpcdc_status_is_ok(st), "struct bidi open");
        n = 0;
        for (;;) {
            EchoResponse out;
            grpcdc_status rst;
            int r = EchoBidiClient_recv(&bidi, &out, &rst);
            if (r == 0) break;
            check(r == 1, "struct bidi recv");
            n++;
        }
        check(n == 2, "struct bidi count");
        EchoBidiClient_close(&bidi);

        /* Struct wire bytes carry the DCS1 magic. */
        EchoPbBytes sb = EchoRequest_struct_marshal(&req);
        check(sb.len > 4 && sb.data[0] == 'D' && sb.data[1] == 'C' &&
                  sb.data[2] == 'S' && sb.data[3] == '1',
              "struct magic");
        free(sb.data);
    }

    /* Struct client against a protobuf-only server: UNIMPLEMENTED. */
    {
        grpcdc_memory_pair *pair = grpcdc_memory_pair_new();
        grpcdc_channel channel;
        EchoClient client = struct_setup(pair, &channel, 1, 0);
        EchoRequest req;
        EchoRequest_init(&req);
        req.message = "hello";
        EchoResponse resp;
        grpcdc_status st = EchoClient_unary(&client, &req, &resp, NULL, 0, 0);
        check(st.code == GRPCDC_UNIMPLEMENTED, "struct mismatch status");
    }

    /* Plain client against a struct-enabled server: protobuf works. */
    {
        grpcdc_memory_pair *pair = grpcdc_memory_pair_new();
        grpcdc_channel channel;
        EchoClient client = struct_setup(pair, &channel, 0, 1);
        EchoRequest req;
        EchoRequest_init(&req);
        req.message = "hello";
        EchoResponse resp;
        grpcdc_status st = EchoClient_unary(&client, &req, &resp, NULL, 0, 0);
        check(grpcdc_status_is_ok(st), "plain vs struct server status");
        check(strcmp(resp.message, "echo: hello") == 0, "plain vs struct body");
    }

    printf("TestStructCodec OK\n");
}
#endif /* GRPCDC_NO_STRUCT_CODEC */

#endif
