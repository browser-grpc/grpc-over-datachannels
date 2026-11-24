#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <string>

#include "msgs_messages.hpp"
#include "msgs_struct.hpp"
#include "msgs2_messages.hpp"
#include "msgs2_struct.hpp"

using namespace shapes;

static std::string Hex(const grpcdc::Bytes& b) {
    char tmp[4];
    std::string out;
    for (auto x : b) { std::snprintf(tmp, sizeof(tmp), "%02x", x); out += tmp; }
    return out;
}

int main(int argc, char** argv) {
    std::string goldenHex = argv[1];
    grpcdc::Bytes golden;
    for (std::size_t i = 0; i + 1 < goldenHex.size(); i += 2)
        golden.push_back(static_cast<std::uint8_t>(std::stoi(goldenHex.substr(i, 2), nullptr, 16)));

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

    auto got = OuterStruct::Marshal(m);
    if (Hex(got) != goldenHex) {
        std::printf("MARSHAL_MISMATCH\n got %s\nwant %s\n", Hex(got).c_str(), goldenHex.c_str());
        return 1;
    }
    auto back = OuterStruct::Unmarshal(golden);
    if (OuterStruct::Marshal(back) != golden) {
        std::printf("ROUNDTRIP_MISMATCH\n");
        return 1;
    }

    std::string golden2Hex = argv[2];
    grpcdc::Bytes golden2;
    for (std::size_t i = 0; i + 1 < golden2Hex.size(); i += 2)
        golden2.push_back(static_cast<std::uint8_t>(std::stoi(golden2Hex.substr(i, 2), nullptr, 16)));

    P2 p2;
    p2.name = "req";
    p2.count = 42;
    p2.greeting = "hi";
    p2.enabled = false;
    p2.ratio = 2.5;
    p2.nums = {5, -6};
    p2.ext_note = "note!";

    auto got2 = P2Struct::Marshal(p2);
    if (Hex(got2) != golden2Hex) {
        std::printf("MARSHAL2_MISMATCH\n got %s\nwant %s\n", Hex(got2).c_str(), golden2Hex.c_str());
        return 1;
    }
    auto back2 = P2Struct::Unmarshal(golden2);
    if (P2Struct::Marshal(back2) != golden2) {
        std::printf("ROUNDTRIP2_MISMATCH\n");
        return 1;
    }
    std::printf("DECODE_OK\n");
    return 0;
}
