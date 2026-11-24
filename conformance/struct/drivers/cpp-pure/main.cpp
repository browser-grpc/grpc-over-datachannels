// Struct corpus driver (cpp, pure/Wasm engine): the pure
// grpcdc::structdc transcoder against the Go golden.
// args: goldenHex descriptorHex
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <string>

#include "msgs_messages.hpp"
#include "msgs2_messages.hpp"
#include "grpcdc/structdc.hpp"

using namespace shapes;

static std::string Hex(const grpcdc::Bytes& b) {
    char tmp[4];
    std::string out;
    for (auto x : b) { std::snprintf(tmp, sizeof(tmp), "%02x", x); out += tmp; }
    return out;
}

static grpcdc::Bytes Unhex(const std::string& s) {
    grpcdc::Bytes out;
    for (std::size_t i = 0; i + 1 < s.size(); i += 2)
        out.push_back(static_cast<std::uint8_t>(std::stoi(s.substr(i, 2), nullptr, 16)));
    return out;
}

int main(int argc, char** argv) {
    std::string goldenHex = argv[1];
    grpcdc::Bytes golden = Unhex(goldenHex);
    grpcdc::Bytes descriptor = Unhex(argv[2]);

    auto mk = [](const char* v, std::int32_t n) {
        Inner in; in.v = v; in.n = n; return in;
    };
    Outer m;
    m.inner = mk("x", -3);
    m.hue = Hue::RED;
    m.nums = {1, -2, 300};
    m.by_name = {{"b", mk("second", 0)}, {"a", mk("first", 9)}};
    m.s = "picked";
    m.blob = {1, 2, 3};
    m.names = {"n1", "n2"};
    m.inners = {mk("i1", 0), mk("i2", 0), mk("i3", 0)};
    m.by_id = {{7, "seven"}, {2, "two"}};
    m.score = 3.5;
    m.ratio = 0.25f;
    m.flag = true;
    m.stamp = 123456789;
    m.delta = -77;

    std::string err;
    grpcdc::Bytes got;
    if (!grpcdc::structdc::Transcode(descriptor, "shapes.Outer", m.MarshalDc(), true, got, err)) {
        std::printf("ENCODE_FAIL %s\n", err.c_str());
        return 1;
    }
    if (got != golden) {
        std::printf("MARSHAL_MISMATCH\n got %s\nwant %s\n", Hex(got).c_str(), goldenHex.c_str());
        return 1;
    }
    grpcdc::Bytes backPb;
    if (!grpcdc::structdc::Transcode(descriptor, "shapes.Outer", golden, false, backPb, err)) {
        std::printf("DECODE_FAIL %s\n", err.c_str());
        return 1;
    }
    Outer back;
    back.UnmarshalDc(backPb);
    grpcdc::Bytes re;
    if (!grpcdc::structdc::Transcode(descriptor, "shapes.Outer", back.MarshalDc(), true, re, err)) {
        std::printf("REENCODE_FAIL %s\n", err.c_str());
        return 1;
    }
    if (re != golden) {
        std::printf("ROUNDTRIP_MISMATCH\n");
        return 1;
    }

    std::string golden2Hex = argv[3];
    grpcdc::Bytes golden2 = Unhex(golden2Hex);
    grpcdc::Bytes descriptor2 = Unhex(argv[4]);

    P2 p2;
    p2.name = "req";
    p2.count = 42;
    p2.greeting = "hi";
    p2.enabled = false;
    p2.ratio = 2.5;
    p2.nums = {5, -6};
    p2.ext_note = "note!";

    grpcdc::Bytes got2;
    if (!grpcdc::structdc::Transcode(descriptor2, "shapes.P2", p2.MarshalDc(), true, got2, err)) {
        std::printf("ENCODE2_FAIL %s\n", err.c_str());
        return 1;
    }
    if (got2 != golden2) {
        std::printf("MARSHAL2_MISMATCH\n got %s\nwant %s\n", Hex(got2).c_str(), golden2Hex.c_str());
        return 1;
    }
    grpcdc::Bytes back2Pb;
    if (!grpcdc::structdc::Transcode(descriptor2, "shapes.P2", golden2, false, back2Pb, err)) {
        std::printf("DECODE2_FAIL %s\n", err.c_str());
        return 1;
    }
    P2 back2;
    back2.UnmarshalDc(back2Pb);
    grpcdc::Bytes re2;
    if (!grpcdc::structdc::Transcode(descriptor2, "shapes.P2", back2.MarshalDc(), true, re2, err)) {
        std::printf("REENCODE2_FAIL %s\n", err.c_str());
        return 1;
    }
    if (re2 != golden2) {
        std::printf("ROUNDTRIP2_MISMATCH\n");
        return 1;
    }
    std::printf("DECODE_OK\n");
    return 0;
}
