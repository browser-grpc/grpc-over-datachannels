#include <cstdio>
#include <optional>
#include <string>
#include <thread>
#include <vector>

#include "tests/proc.hpp"
#include "tests/test_util.hpp"

namespace tests {
namespace {

const char* kCases[] = {
    "empty_unary",
    "large_unary",
    "client_streaming",
    "server_streaming",
    "ping_pong",
    "empty_stream",
    "custom_metadata",
    "status_code_and_message",
    "special_status_message",
    "unimplemented_method",
    "unimplemented_service",
    "cancel_after_begin",
    "cancel_after_first_response",
    "timeout_on_sleeping_server",
};

const char* kJavaOnlyCases[] = {
    "cacheable_unary",
    "client_compressed_unary",
    "client_compressed_streaming",
    "server_compressed_unary",
    "server_compressed_streaming",
};

const char* kGoOnlyCases[] = {"orca_per_rpc", "orca_oob"};

std::optional<std::string> JavaClasspath(const std::string& root) {
  std::string target = root + "/oracle/java/target";
  std::string cp_file = target + "/cp.txt";
  if (!FileExists(cp_file) || !FileExists(target + "/classes")) {
    return std::nullopt;
  }
  FILE* f = std::fopen(cp_file.c_str(), "r");
  std::string cp = ReadAll(f);
  std::fclose(f);
  while (!cp.empty() && (cp.back() == '\n' || cp.back() == '\r')) cp.pop_back();
  return target + "/classes:" + cp;
}

std::string RunClient(const std::vector<std::string>& argv) {
  Proc proc;
  Check(Spawn(argv, true, proc), "client spawn");
  std::string out_text, err_text;
  std::thread t1([&] { out_text = ReadAll(proc.from_stdout); });
  std::thread t2([&] { err_text = ReadAll(proc.from_stderr); });
  int code = proc.WaitForExit(120000);
  t1.join();
  t2.join();
  std::string all = out_text + err_text;
  Check(code == 0, "client exit " + std::to_string(code) + ": " + argv[0] + "\n" + all);
  return all;
}

bool WaitReady(FILE* f, const std::string& needle) {
  char buf[4096];
  std::string acc;
  while (std::fgets(buf, sizeof(buf), f) != nullptr) {
    acc += buf;
    if (acc.find(needle) != std::string::npos) return true;
  }
  return false;
}

}  // namespace

/// Interop oracle, Direction B: the OFFICIAL interop clients
/// (grpc-java TestServiceClient, grpc-go interop-client) run the
/// canonical cases against the generated C++ TestService server
/// (examples/interop_server_stdio), reached over HTTP/2 through
/// oracle/bridge.mjs http2-to-dc. Skips when an oracle binary or
/// Node is unavailable. Mirrors
/// java/tests/TestInteropServerOracle.java.
void TestInteropServerOracle() {
  std::string root = Root();
  auto cp = JavaClasspath(root);
  if (!cp) {
    std::printf("TestInteropServerOracle SKIP (oracle not built)\n");
    return;
  }
  std::string server_bin = root + "/cpp/build/interop_server_stdio";
  if (!FileExists(server_bin)) {
    std::printf("TestInteropServerOracle SKIP (cpp server not built)\n");
    return;
  }
  int port = FreePort();
  Proc bridge;
  bool spawned = Spawn({"node", root + "/oracle/bridge.mjs", "http2-to-dc",
                        "--port", std::to_string(port),
                        "--target-cmd", server_bin},
                       true, bridge);
  if (!spawned || !WaitReady(bridge.from_stderr, "listening")) {
    bridge.Kill();
    std::printf("TestInteropServerOracle SKIP (bridge did not start)\n");
    return;
  }
  std::thread drain_err([&] { ReadAll(bridge.from_stderr); });
  drain_err.detach();
  std::vector<std::string> java_cases(std::begin(kCases), std::end(kCases));
  java_cases.insert(java_cases.end(), std::begin(kJavaOnlyCases), std::end(kJavaOnlyCases));
  for (const std::string& test_case : java_cases) {
    std::string out = RunClient({"java", "-cp", *cp,
                                 "io.grpc.testing.integration.TestServiceClient",
                                 "--server_host=127.0.0.1",
                                 "--server_port=" + std::to_string(port),
                                 "--test_case=" + test_case, "--use_tls=false"});
    Check(out.find("Test completed.") != std::string::npos,
          "java case " + test_case + ": unexpected output: " + out);
    std::printf("interop B case ok: %s (java client)\n", test_case.c_str());
  }
  std::string go_client = root + "/oracle/go-interop/interop-client";
  if (!FileExists(go_client)) {
    std::printf("TestInteropServerOracle GO SKIP (go client not built)\n");
  } else {
    std::vector<std::string> go_cases(std::begin(kCases), std::end(kCases));
    go_cases.insert(go_cases.end(), std::begin(kGoOnlyCases), std::end(kGoOnlyCases));
    for (const std::string& test_case : go_cases) {
      std::vector<std::string> argv = {go_client,
                                       "-server_host", "127.0.0.1",
                                       "-server_port", std::to_string(port),
                                       "-test_case", test_case};
      if (test_case.rfind("orca", 0) == 0) {
        argv.push_back("-service_config_json");
        argv.push_back("{ \"loadBalancingConfig\": [{ \"test_backend_metrics_load_balancer\": {} }]}");
      }
      RunClient(argv);
      std::printf("interop B case ok: %s (go client)\n", test_case.c_str());
    }
  }
  bridge.Kill();
  std::printf("TestInteropServerOracle OK\n");
}

}  // namespace tests
