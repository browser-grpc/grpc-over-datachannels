// Struct corpus driver (cpp, pure/Wasm engine): the pure
// grpcdc::structdc transcoder against the Go golden.
// args: goldenHex descriptorHex
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <string>

#include "msgs_messages.hpp"
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
    std::printf("DECODE_OK\n");
    return 0;
}
