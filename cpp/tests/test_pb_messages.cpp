// Generated C++ message types (<base>_messages.hpp) from the
// native protoc-gen-grpc-dc-cpp plugin: kitchen-sink round-trip
// plus a protoc oracle — protoc's own --encode bytes must decode
// to the same message and re-encode semantically identically.

#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <sstream>
#include <stdexcept>
#include <string>
#include <unistd.h>

namespace tests {
namespace {

std::string ReadFile(const std::string& path) {
  std::ifstream in(path, std::ios::binary);
  std::stringstream ss;
  ss << in.rdbuf();
  return ss.str();
}

void Check(bool ok, const std::string& what) {
  if (!ok) throw std::runtime_error("check failed: " + what);
}

const char* kHarness = R"HARNESS(
#include "kitchen_messages.hpp"
#include <cmath>
#include <cstdio>
#include <fstream>
#include <sstream>
#include <string>

static void Fail(const char* msg) {
  std::fprintf(stderr, "FAIL: %s\n", msg);
  std::exit(1);
}

static kitchen::v1::Kitchen Make() {
  kitchen::v1::Kitchen k;
  k.d = 1.5; k.f = 2.5f; k.i32 = -3; k.i64 = -4; k.u32 = 5; k.u64 = 6;
  k.s32 = -7; k.s64 = -8; k.f32 = 9; k.f64 = 10; k.sf32 = -11; k.sf64 = -12;
  k.flag = true; k.name = "sink"; k.blob = {1, 2, 3};
  k.color = kitchen::v1::Color::GREEN;
  kitchen::v1::Nested nested; nested.note = "n"; nested.level = 3;
  k.nested = nested;
  shop::common::Item item; item.sku = "abc"; item.quantity = 2;
  k.item = item;
  k.nums = {1, -2, 300};
  k.words = {"a", "", "bc"};
  kitchen::v1::Nested m; m.note = "m"; m.level = 1;
  k.manys = {m};
  k.vals = {0.5, -1.25};
  k.counts = {{"x", 1}, {"y", -2}};
  kitchen::v1::Nested z; z.note = "z"; z.level = 9;
  k.by_id = {{7, z}};
  k.text = "chosen"; k.big_negative = -9007199254740993LL; k.neg32 = -123456;
  return k;
}

static void CheckSame(const kitchen::v1::Kitchen& a, const kitchen::v1::Kitchen& b) {
  bool ok = a.d == b.d && a.f == b.f && a.i32 == b.i32 && a.i64 == b.i64
      && a.u32 == b.u32 && a.u64 == b.u64 && a.s32 == b.s32 && a.s64 == b.s64
      && a.f32 == b.f32 && a.f64 == b.f64 && a.sf32 == b.sf32 && a.sf64 == b.sf64
      && a.flag == b.flag && a.name == b.name && a.blob == b.blob && a.color == b.color
      && a.nested->note == b.nested->note && a.nested->level == b.nested->level
      && a.item->sku == b.item->sku && a.item->quantity == b.item->quantity
      && a.nums == b.nums && a.words == b.words
      && a.manys.size() == b.manys.size() && a.manys[0].note == b.manys[0].note
      && a.vals == b.vals && a.counts == b.counts
      && a.by_id.at(7).note == b.by_id.at(7).note
      && a.text == b.text && a.big_negative == b.big_negative && a.neg32 == b.neg32;
  if (!ok) Fail("mismatch");
}

int main(int argc, char** argv) {
  auto k = Make();
  if (std::string(argv[1]) == "roundtrip") {
    kitchen::v1::Kitchen back;
    back.UnmarshalDc(k.MarshalDc());
    CheckSame(back, k);
    if (!kitchen::v1::Kitchen().MarshalDc().empty()) Fail("empty must encode empty");
    kitchen::v1::Kitchen both;
    both.text = "a"; both.code = 7;
    kitchen::v1::Kitchen both_back;
    both_back.UnmarshalDc(both.MarshalDc());
    if (!both_back.text.empty() || both_back.code != 7) Fail("oneof encode clearing");
    std::printf("roundtrip OK\n");
    return 0;
  }
  std::ifstream in(argv[2], std::ios::binary);
  std::stringstream ss;
  ss << in.rdbuf();
  std::string bytes = ss.str();
  kitchen::v1::Kitchen from;
  from.UnmarshalDc(grpcdc::Bytes(bytes.begin(), bytes.end()));
  CheckSame(from, k);
  kitchen::v1::Kitchen again;
  again.UnmarshalDc(from.MarshalDc());
  CheckSame(again, from);
  std::printf("oracle OK\n");
  return 0;
}
)HARNESS";

const char* kKitchenText =
    "d: 1.5 f: 2.5 i32: -3 i64: -4 u32: 5 u64: 6 s32: -7 s64: -8\n"
    "f32: 9 f64: 10 sf32: -11 sf64: -12 flag: true name: \"sink\"\n"
    "blob: \"\\x01\\x02\\x03\" color: GREEN\n"
    "nested { note: \"n\" level: 3 }\n"
    "item { sku: \"abc\" quantity: 2 }\n"
    "nums: [1, -2, 300] words: [\"a\", \"\", \"bc\"]\n"
    "manys { note: \"m\" level: 1 }\n"
    "vals: [0.5, -1.25]\n"
    "counts { key: \"x\" value: 1 } counts { key: \"y\" value: -2 }\n"
    "by_id { key: 7 value { note: \"z\" level: 9 } }\n"
    "text: \"chosen\" big_negative: -9007199254740993 neg32: -123456\n";

}  // namespace

std::string Capture(const std::string& cmd, const std::string& stdin_text) {
  std::string in_path;
  std::string full = cmd;
  if (!stdin_text.empty()) {
    in_path = std::string("/tmp/grpcdc-cpp-pb-stdin.txt");
    std::ofstream o(in_path, std::ios::binary);
    o << stdin_text;
    o.close();
    full += " < " + in_path;
  }
  FILE* pipe = popen(full.c_str(), "r");
  Check(pipe != nullptr, "popen: " + cmd);
  std::string out;
  char buf[4096];
  std::size_t n;
  while ((n = std::fread(buf, 1, sizeof(buf), pipe)) > 0) out.append(buf, n);
  int rc = pclose(pipe);
  Check(rc == 0, "command failed: " + cmd);
  return out;
}

void WriteFile(const std::string& path, const std::string& content) {
  std::ofstream o(path, std::ios::binary);
  o << content;
  Check(o.good(), "write " + path);
}

void TestPbMessages() {
  std::string root = "..";
  if (!std::ifstream(root + "/webapp/testdata/kitchen.proto").good()) {
    root = ".";
  }
  std::string testdata = root + "/webapp/testdata";
  char tmpl[] = "/tmp/grpcdc-cpp-pb-XXXXXX";
  Check(mkdtemp(tmpl) != nullptr, "mkdtemp");
  std::string tmp = tmpl;
  std::string gen = tmp + "/gen";
  Check(std::system(("mkdir -p " + gen).c_str()) == 0, "mkdir gen");
  Capture("protoc --plugin=protoc-gen-grpc-dc-cpp=" + root +
              "/bin/protoc-gen-grpc-dc-cpp --grpc-dc-cpp_out=" + gen + " -I " +
              testdata + " common.proto kitchen.proto",
          "");
  std::remove((gen + "/common_grpc_dc.hpp").c_str());
  std::remove((gen + "/kitchen_grpc_dc.hpp").c_str());
  WriteFile(gen + "/harness.cpp", kHarness);
  Capture("g++ -std=c++17 -I " + gen + " -I " + root + "/cpp " + gen +
              "/harness.cpp -o " + tmp + "/harness 2>&1",
          "");
  std::string out = Capture(tmp + "/harness roundtrip", "");
  Check(out.find("roundtrip OK") != std::string::npos, "roundtrip: " + out);
  std::string protoc_bytes = Capture(
      "protoc --encode=kitchen.v1.Kitchen -I " + testdata + " kitchen.proto",
      kKitchenText);
  WriteFile(tmp + "/protoc.bin", protoc_bytes);
  out = Capture(tmp + "/harness oracle " + tmp + "/protoc.bin", "");
  Check(out.find("oracle OK") != std::string::npos, "oracle: " + out);
  std::printf("TestPbMessages OK\n");
}

}  // namespace tests
