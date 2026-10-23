#include <cstdio>
#include <memory>
#include <optional>
#include <string>
#include <vector>

#include "examples/echo_grpc_dc.hpp"
#include "examples/echo_messages.hpp"
#include "examples/stdio_transport.hpp"
#include "grpcdc/channel.hpp"
#include "tests/oracle_scenarios.hpp"
#include "tests/proc.hpp"
#include "tests/test_util.hpp"

namespace tests {
namespace {

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

std::string Unmsg(const char* token) {
  return std::string(token) == "-" ? "" : std::string(token);
}

echo::EchoRequest Req(const std::string& m, std::int32_t c) {
  echo::EchoRequest r; r.message = m; r.count = c; return r;
}

std::vector<echo::EchoRequest> Reqs(const std::vector<std::string>& messages) {
  std::vector<echo::EchoRequest> out;
  for (auto& m : messages) out.push_back(Req(m, 0));
  return out;
}

void RunScenarios(echo::EchoGrpcDc::EchoClient& client) {
  for (auto& c : OracleCases()) {
    std::string kind = c.kind;
    std::vector<std::string> messages;
    std::string line = kind;
    for (auto* m : c.messages) {
      messages.push_back(Unmsg(m));
      line += " " + std::string(m);
    }
    if (kind == "UNARY") {
      try {
        echo::EchoResponse resp = client.Unary(Req(messages[0], 0));
        Check(c.expect_status < 0, line + ": expected failure");
        Check(resp.message == "echo: " + messages[0] && resp.index == 0,
              line + ": " + resp.message);
      } catch (const grpcdc::StatusException& e) {
        Check(c.expect_status >= 0 && e.code() == c.expect_status,
              line + ": status " + std::string(e.what()));
      }
    } else if (kind == "SERVER_STREAM") {
      auto stream = client.ServerStream(Req(messages[0], c.count));
      int got = 0;
      while (true) {
        echo::EchoResponse resp;
        try {
          resp = stream.Recv();
        } catch (const grpcdc::EndOfStream&) {
          break;
        }
        Check(resp.message == messages[0] && resp.index == got,
              line + ": " + resp.message);
        ++got;
      }
      Check(got == c.count, line + ": count");
    } else if (kind == "CLIENT_STREAM") {
      echo::EchoResponse resp = client.ClientStream(Reqs(messages));
      std::string joined;
      for (std::size_t i = 0; i < messages.size(); ++i) {
        if (i) joined += "+";
        joined += messages[i];
      }
      Check(resp.message == joined &&
                resp.index == static_cast<std::int32_t>(messages.size()),
            line + ": " + resp.message);
    } else if (kind == "BIDI") {
      auto stream = client.Bidi(Reqs(messages));
      int got = 0;
      while (true) {
        echo::EchoResponse resp;
        try {
          resp = stream.Recv();
        } catch (const grpcdc::EndOfStream&) {
          break;
        }
        Check(got < static_cast<int>(messages.size()) &&
                  resp.message == messages[got] && resp.index == got,
              line + ": " + resp.message);
        ++got;
      }
      Check(got == static_cast<int>(messages.size()), line + ": count");
    } else {
      Check(false, "unknown scenario kind: " + kind);
    }
  }
}

bool WaitReady(FILE* stderr_pipe, const char* needle) {
  char line[1024];
  while (std::fgets(line, sizeof(line), stderr_pipe)) {
    if (std::string(line).find(needle) != std::string::npos) return true;
  }
  return false;
}

}  // namespace

/// Oracle: official grpc-java, bridged over TCP<->DataChannel by
/// oracle/bridge.mjs, must agree with the C++ runtime on every case
/// of the generated scenario driver. Skips when the Java oracle or
/// Node bridge are unavailable (Dockerfile.ci provides both).
void TestOracle() {
  std::string root = Root();
  auto cp = JavaClasspath(root);
  if (!cp) {
    std::fprintf(stderr, "TestOracle SKIP (java oracle not built)\n");
    return;
  }

  // Direction A: this client -> bridge -> official server.
  int port = FreePort();
  Proc server;
  if (!Spawn({"java", "-cp", *cp, "dc.oracle.OracleServer",
              std::to_string(port)},
             true, server)) {
    std::fprintf(stderr, "TestOracle SKIP (spawn java)\n");
    return;
  }
  if (!WaitReady(server.from_stderr, "READY")) {
    std::fprintf(stderr, "TestOracle SKIP (oracle server did not start)\n");
    server.Kill();
    return;
  }
  {
    Proc bridge;
    if (!Spawn({"node", root + "/oracle/bridge.mjs", "dc-to-http2", "--grpc",
                "127.0.0.1:" + std::to_string(port)},
               false, bridge)) {
      std::fprintf(stderr, "TestOracle SKIP (spawn bridge)\n");
      server.Kill();
      return;
    }
    auto transport = std::make_shared<echo::StdioTransport>(bridge.to_stdin,
                                                           bridge.from_stdout);
    auto channel = std::make_shared<grpcdc::Channel>(transport);
    echo::EchoGrpcDc::EchoClient client(channel);
    RunScenarios(client);
    bridge.Kill();
  }
  server.Kill();

  // Direction B: official client -> bridge -> this runtime's server.
  std::string server_bin = root + "/cpp/build/echo_server_stdio";
  if (!FileExists(server_bin)) {
    std::fprintf(stderr, "TestOracle SKIP (cpp server not built)\n");
    return;
  }
  int port_b = FreePort();
  Proc bridge;
  if (!Spawn({"node", root + "/oracle/bridge.mjs", "http2-to-dc", "--port",
              std::to_string(port_b), "--target-cmd", server_bin},
             true, bridge)) {
    std::fprintf(stderr, "TestOracle SKIP (bridge spawn)\n");
    return;
  }
  if (!WaitReady(bridge.from_stderr, "listening")) {
    std::fprintf(stderr, "TestOracle SKIP (bridge did not start)\n");
    bridge.Kill();
    return;
  }
  {
    Proc client;
    if (!Spawn({"java", "-cp", *cp, "dc.oracle.OracleClient",
                std::to_string(port_b),
                root + "/fixtures/oracle_scenarios.txt"},
               true, client)) {
      std::fprintf(stderr, "TestOracle SKIP (client spawn)\n");
      bridge.Kill();
      return;
    }
    std::string output = ReadAll(client.from_stdout);
    int exit_code = client.WaitForExit(120000);
    std::string err = client.from_stderr ? ReadAll(client.from_stderr) : "";
    Check(exit_code == 0, "oracle client failed:\n" + output + err);
    Check(output.find("ORACLE CLIENT: ALL OK") != std::string::npos,
          "oracle client output:\n" + output + err);
    client.Kill();
  }
  bridge.Kill();
  std::fprintf(stderr, "TestOracle OK\n");
}

}  // namespace tests
