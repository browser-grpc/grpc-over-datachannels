// BDD schema scenarios: golden protoc bytes, generated classes.
// The case table (bdd_schemas.hpp) is generated from
// the schema scenarios: protoc's own --encode output over
// webapp/testdata/{kitchen,features}.proto. Each case decodes
// with the generated classes and re-encodes byte-identically.
// The generated-classes harness mirrors test_pb_messages.cpp.

#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <sstream>
#include <stdexcept>
#include <string>

#include "bdd_schemas.hpp"

namespace tests {
namespace {

void Check(bool ok, const std::string& what) {
  if (!ok) throw std::runtime_error("check failed: " + what);
}

std::string Capture(const std::string& cmd) {
  FILE* pipe = popen(cmd.c_str(), "r");
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

const char* kHarnessHead = R"HARNESS(
#include "kitchen_messages.hpp"
#include "features_messages.hpp"
#include <cstdio>
#include <string>
#include <vector>

static void Fail(const std::string& msg) {
  std::fprintf(stderr, "FAIL: %s\n", msg.c_str());
  std::exit(1);
}

struct Case { const char* name; const char* message; const char* input; const char* expect; };

static std::vector<unsigned char> Unhex(const char* s) {
  std::vector<unsigned char> out;
  for (std::size_t i = 0; s[i] && s[i + 1]; i += 2) {
    auto v = [](char c) -> unsigned {
      if (c >= '0' && c <= '9') return c - '0';
      if (c >= 'a' && c <= 'f') return c - 'a' + 10;
      return c - 'A' + 10;
    };
    out.push_back(static_cast<unsigned char>(v(s[i]) * 16 + v(s[i + 1])));
  }
  return out;
}

static std::string Hex(const std::vector<unsigned char>& bytes) {
  std::string out;
  for (unsigned char b : bytes) {
    char buf[3];
    std::snprintf(buf, sizeof(buf), "%02x", b);
    out += buf;
  }
  return out;
}

int main() {
  const Case cases[] = {
)HARNESS";

const char* kHarnessTail = R"HARNESS(
  };
  for (const Case& c : cases) {
    auto input = Unhex(c.input);
    std::vector<unsigned char> got;
    if (std::string(c.message) == "kitchen") {
      kitchen::v1::Kitchen m;
      m.UnmarshalDc(input);
      got = m.MarshalDc();
    } else if (std::string(c.message) == "outer") {
      feat::v1::Outer m;
      m.UnmarshalDc(input);
      got = m.MarshalDc();
    } else {
      Fail(std::string("unknown message: ") + c.message);
    }
    if (Hex(got) != c.expect) Fail(std::string("re-encode mismatch: ") + c.name);
  }
  std::printf("schemas OK\n");
  return 0;
}
)HARNESS";

}  // namespace

void TestBddSchemas() {
  std::string root = "..";
  if (!std::ifstream(root + "/webapp/testdata/kitchen.proto").good()) {
    root = ".";
  }
  std::string testdata = root + "/webapp/testdata";
  char tmpl[] = "/tmp/grpcdc-cpp-schemas-XXXXXX";
  Check(mkdtemp(tmpl) != nullptr, "mkdtemp");
  std::string tmp = tmpl;
  std::string gen = tmp + "/gen";
  Check(std::system(("mkdir -p " + gen).c_str()) == 0, "mkdir gen");
  Capture("protoc --plugin=protoc-gen-grpc-dc-cpp=" + root +
          "/bin/protoc-gen-grpc-dc-cpp --grpc-dc-cpp_out=" + gen + " -I " +
          testdata + " common.proto kitchen.proto features.proto");
  std::remove((gen + "/common_grpc_dc.hpp").c_str());
  std::remove((gen + "/kitchen_grpc_dc.hpp").c_str());
  std::remove((gen + "/features_grpc_dc.hpp").c_str());

  std::string harness = kHarnessHead;
  for (const auto& c : BddSchemaCases()) {
    harness += "      {\"" + std::string(c.name) + "\", \"" + c.message +
               "\", \"" + c.input + "\", \"" + c.expect + "\"},\n";
  }
  harness += kHarnessTail;
  WriteFile(gen + "/harness.cpp", harness);
  Capture("g++ -std=c++17 -I " + gen + " -I " + root + "/cpp " + gen +
          "/harness.cpp -o " + tmp + "/harness 2>&1");
  std::string out = Capture(tmp + "/harness");
  Check(out.find("schemas OK") != std::string::npos, "schemas: " + out);
  std::printf("TestBddSchemas OK\n");
}

}  // namespace tests
