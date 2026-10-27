// Test runner: ./tests <TestCodec|TestEcho|TestInterop|TestOracle|TestDynamic>
#include <cstdio>
#include <cstring>
#include <exception>
#include <string>

namespace tests {
void TestCodec();
void TestEcho();
void TestEventBus();
void TestInterop();
void TestInteropOracle();
void TestInteropServerOracle();
void TestOracle();
void TestDynamic();
void TestBdd();
void TestDeadline();
void TestInlinePump();
void TestPbMessages();
void TestBddSchemas();
void TestSidecar();
void TestBddSidecar();
}  // namespace tests

int main(int argc, char** argv) {
  if (argc < 2) {
    std::fprintf(stderr,
                 "usage: tests <TestCodec|TestEcho|TestInterop|TestOracle|"
                 "TestDynamic|TestBdd|TestDeadline|TestInlinePump>\n");
    return 2;
  }
  std::string name = argv[1];
  try {
    if (name == "TestCodec") {
      tests::TestCodec();
    } else if (name == "TestEcho") {
      tests::TestEcho();
    } else if (name == "TestEventBus") {
      tests::TestEventBus();
    } else if (name == "TestInterop") {
      tests::TestInterop();
    } else if (name == "TestInteropOracle") {
      tests::TestInteropOracle();
    } else if (name == "TestInteropServerOracle") {
      tests::TestInteropServerOracle();
    } else if (name == "TestOracle") {
      tests::TestOracle();
    } else if (name == "TestDynamic") {
      tests::TestDynamic();
    } else if (name == "TestBdd") {
      tests::TestBdd();
    } else if (name == "TestDeadline") {
      tests::TestDeadline();
    } else if (name == "TestInlinePump") {
      tests::TestInlinePump();
    } else if (name == "TestPbMessages") {
      tests::TestPbMessages();
    } else if (name == "TestBddSchemas") {
      tests::TestBddSchemas();
    } else if (name == "TestSidecar") {
      tests::TestSidecar();
    } else if (name == "TestBddSidecar") {
      tests::TestBddSidecar();
    } else {
      std::fprintf(stderr, "unknown test: %s\n", name.c_str());
      return 2;
    }
    return 0;
  } catch (const std::exception& e) {
    std::fprintf(stderr, "%s\n", e.what());
    return 1;
  }
}
