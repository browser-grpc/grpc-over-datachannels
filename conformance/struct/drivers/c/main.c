#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "msgs_messages.h"
#include "msgs_struct.h"
#include "msgs2_messages.h"
#include "msgs2_struct.h"

static char *dupstr(const char *s) {
    size_t n = strlen(s);
    char *r = (char *)malloc(n + 1);
    memcpy(r, s, n + 1);
    return r;
}

static void hexof(const uint8_t *b, size_t n, char *out) {
    static const char *h = "0123456789abcdef";
    for (size_t i = 0; i < n; i++) { out[2 * i] = h[b[i] >> 4]; out[2 * i + 1] = h[b[i] & 15]; }
    out[2 * n] = 0;
}

int main(int argc, char **argv) {
    const char *goldenHex = argv[1];
    size_t glen = strlen(goldenHex) / 2;
    uint8_t *golden = (uint8_t *)malloc(glen);
    for (size_t i = 0; i < glen; i++) {
        unsigned int v;
        sscanf(goldenHex + 2 * i, "%2x", &v);
        golden[i] = (uint8_t)v;
    }

    Outer m;
    memset(&m, 0, sizeof(m));
    Inner inner; memset(&inner, 0, sizeof(inner));
    inner.v = dupstr("x"); inner.n = -3;
    m.inner = &inner;
    m.hue = Hue_RED;
    m.nums = (int32_t *)malloc(3 * sizeof(int32_t));
    m.nums[0] = 1; m.nums[1] = -2; m.nums[2] = 300; m.nums_count = 3;
    m.by_name = (Outer_ByNameEntry *)malloc(2 * sizeof(Outer_ByNameEntry));
    m.by_name[0].key = dupstr("b"); m.by_name[0].value.v = dupstr("second"); m.by_name[0].value.n = 0;
    m.by_name[1].key = dupstr("a"); m.by_name[1].value.v = dupstr("first"); m.by_name[1].value.n = 9;
    m.by_name_count = 2;
    m.s = dupstr("picked");
    m.blob.data = (uint8_t *)malloc(3); m.blob.data[0] = 1; m.blob.data[1] = 2; m.blob.data[2] = 3; m.blob.len = 3;
    m.names = (char **)malloc(2 * sizeof(char *));
    m.names[0] = dupstr("n1"); m.names[1] = dupstr("n2"); m.names_count = 2;
    m.inners = (Inner *)malloc(3 * sizeof(Inner));
    memset(m.inners, 0, 3 * sizeof(Inner));
    m.inners[0].v = dupstr("i1"); m.inners[1].v = dupstr("i2"); m.inners[2].v = dupstr("i3");
    m.inners_count = 3;
    m.by_id = (Outer_ByIdEntry *)malloc(2 * sizeof(Outer_ByIdEntry));
    m.by_id[0].key = 7; m.by_id[0].value = dupstr("seven");
    m.by_id[1].key = 2; m.by_id[1].value = dupstr("two");
    m.by_id_count = 2;
    m.score = 3.5; m.ratio = 0.25f; m.flag = true; m.stamp = 123456789; m.delta = -77;

    MsgsPbBytes got = Outer_struct_marshal(&m);
    char *gotHex = (char *)malloc(2 * got.len + 1);
    hexof(got.data, got.len, gotHex);
    if (strcmp(gotHex, goldenHex) != 0) {
        printf("MARSHAL_MISMATCH\n got %s\nwant %s\n", gotHex, goldenHex);
        return 1;
    }
    Outer back; memset(&back, 0, sizeof(back));
    if (!Outer_struct_unmarshal(&back, golden, glen)) { printf("DECODE_FAIL\n"); return 1; }
    MsgsPbBytes rt = Outer_struct_marshal(&back);
    char *rtHex = (char *)malloc(2 * rt.len + 1);
    hexof(rt.data, rt.len, rtHex);
    if (strcmp(rtHex, goldenHex) != 0) { printf("ROUNDTRIP_MISMATCH\n"); return 1; }

    const char *golden2Hex = argv[2];
    size_t g2len = strlen(golden2Hex) / 2;
    uint8_t *golden2 = (uint8_t *)malloc(g2len);
    for (size_t i = 0; i < g2len; i++) {
        unsigned int v;
        sscanf(golden2Hex + 2 * i, "%2x", &v);
        golden2[i] = (uint8_t)v;
    }

    P2 p2;
    memset(&p2, 0, sizeof(p2));
    p2.name = dupstr("req");
    p2.count = 42;
    p2.greeting = dupstr("hi");
    p2.enabled = false;
    p2.ratio = 2.5;
    p2.nums = (int32_t *)malloc(2 * sizeof(int32_t));
    p2.nums[0] = 5; p2.nums[1] = -6; p2.nums_count = 2;
    p2.ext_note = dupstr("note!");

    Msgs2PbBytes got2 = P2_struct_marshal(&p2);
    char *got2Hex = (char *)malloc(2 * got2.len + 1);
    hexof(got2.data, got2.len, got2Hex);
    if (strcmp(got2Hex, golden2Hex) != 0) {
        printf("MARSHAL2_MISMATCH\n got %s\nwant %s\n", got2Hex, golden2Hex);
        return 1;
    }
    P2 back2; memset(&back2, 0, sizeof(back2));
    if (!P2_struct_unmarshal(&back2, golden2, g2len)) { printf("DECODE2_FAIL\n"); return 1; }
    Msgs2PbBytes rt2 = P2_struct_marshal(&back2);
    char *rt2Hex = (char *)malloc(2 * rt2.len + 1);
    hexof(rt2.data, rt2.len, rt2Hex);
    if (strcmp(rt2Hex, golden2Hex) != 0) { printf("ROUNDTRIP2_MISMATCH\n"); return 1; }
    printf("DECODE_OK\n");
    return 0;
}
