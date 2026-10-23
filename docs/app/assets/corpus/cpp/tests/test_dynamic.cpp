#include <cstdio>
#include <fstream>
#include <memory>
#include <optional>
#include <string>
#include <vector>

#include "examples/dynamic_echo_service.hpp"
#include "examples/stdio_transport.hpp"
#include "grpcdc/channel.hpp"
#include "grpcdc/dynamic.hpp"
#include "grpcdc/memory_transport.hpp"
#include "grpcdc/server.hpp"
#include "tests/oracle_scenarios.hpp"
#include "tests/proc.hpp"
#include "tests/test_util.hpp"

namespace tests {
namespace {

using grpcdc::dynamic::DynamicClient;
using grpcdc::dynamic::FileModel;
using grpcdc::dynamic::GenericMessage;
using grpcdc::dynamic::GenericValue;

const char* kService = "echo.Echo";

std::shared_ptr<FileModel> LoadModel(const std::string& root) {
  std::ifstream in(root + "/fixtures/echo_descriptor_set.bin", std::ios::binary);
  if (!in) return nullptr;
  grpcdc::Bytes bytes((std::istreambuf_iterator<char>(in)),
                      std::istreambuf_iterator<char>());
  return std::make_shared<FileModel>(grpcdc::dynamic::ParseDescriptorSet(bytes));
}

GenericMessage Req(FileModel& model, const std::string& message,
                   std::int64_t count) {
  GenericMessage m(model.message(".echo.EchoRequest"));
  m.Set(1, GenericValue(message));
  m.Set(2, GenericValue(count));
  return m;
}

std::vector<GenericMessage> Reqs(FileModel& model,
                                 const std::vector<std::string>& messages) {
  std::vector<GenericMessage> out;
  for (auto& m : messages) out.push_back(Req(model, m, 0));
  return out;
}

std::string Unmsg(const char* token) {
  return std::string(token) == "-" ? "" : std::string(token);
}

void RunScenarios(DynamicClient& client, FileModel& model) {
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
        GenericMessage resp = client.Unary(kService, "Unary", Req(model, messages[0], 0));
        Check(c.expect_status < 0, line + ": expected failure");
        Check(resp.GetString(1) == "echo: " + messages[0] && resp.GetInt(2) == 0,
              line + ": bad unary resp");
      } catch (const grpcdc::StatusException& e) {
        Check(c.expect_status >= 0 && e.code() == c.expect_status,
              line + ": status " + std::string(e.what()));
      }
    } else if (kind == "SERVER_STREAM") {
      auto stream =
          client.ServerStream(kService, "ServerStream", Req(model, messages[0], c.count));
      int got = 0;
      while (true) {
        GenericMessage resp;
        try {
          resp = stream.Recv();
        } catch (const grpcdc::EndOfStream&) {
          break;
        }
        Check(resp.GetString(1) == messages[0] && resp.GetInt(2) == got,
              line + ": bad stream resp");
        ++got;
      }
      Check(got == c.count, line + ": count");
    } else if (kind == "CLIENT_STREAM") {
      GenericMessage resp =
          client.ClientStream(kService, "ClientStream", Reqs(model, messages));
      std::string joined;
      for (std::size_t i = 0; i < messages.size(); ++i) {
        if (i) joined += "+";
        joined += messages[i];
      }
      Check(resp.GetString(1) == joined &&
                resp.GetInt(2) == static_cast<std::int64_t>(messages.size()),
            line + ": bad client-stream resp");
    } else if (kind == "BIDI") {
      auto stream = client.Bidi(kService, "Bidi", Reqs(model, messages));
      int got = 0;
      while (true) {
        GenericMessage resp;
        try {
          resp = stream.Recv();
        } catch (const grpcdc::EndOfStream&) {
          break;
        }
        Check(got < static_cast<int>(messages.size()) &&
                  resp.GetString(1) == messages[got] && resp.GetInt(2) == got,
              line + ": bad bidi resp");
        ++got;
      }
      Check(got == static_cast<int>(messages.size()), line + ": count");
    } else {
      Check(false, "unknown scenario kind: " + kind);
    }
  }
}

std::optional<std::string> JavaClasspath(const std::string& root) {
  std::string target = root + "/oracle/java/target";
  if (!FileExists(target + "/cp.txt") || !FileExists(target + "/classes")) {
    return std::nullopt;
  }
  FILE* f = std::fopen((target + "/cp.txt").c_str(), "r");
  std::string cp = ReadAll(f);
  std::fclose(f);
  while (!cp.empty() && (cp.back() == '\n' || cp.back() == '\r')) cp.pop_back();
  return target + "/classes:" + cp;
}

bool WaitReady(FILE* stderr_pipe, const char* needle) {
  char line[1024];
  while (std::fgets(line, sizeof(line), stderr_pipe)) {
    if (std::string(line).find(needle) != std::string::npos) return true;
  }
  return false;
}

}  // namespace

/// Dynamic (descriptor-driven) runtime: schemas consumed as data at
/// runtime, no generated stubs. Loopback plus the official grpc-java
/// oracle in both directions (the oracle is the runtime test bed).
void TestDynamic() {
  std::string root = Root();
  auto model = LoadModel(root);
  if (!model) {
    std::fprintf(stderr, "TestDynamic SKIP (descriptor fixture missing)\n");
    return;
  }

  // Generic codec + unknown-field retention round trip.
  {
    auto request_type = model->message(".echo.EchoRequest");
    grpcdc::Bytes payload = {0x0a, 0x02, 'h', 'i', 0x10, 0x02,
                             0x98, 0x06, 0x2a, 0xa2, 0x06, 0x01, 'x'};
    GenericMessage decoded =
        grpcdc::dynamic::DecodeGeneric(*request_type, payload, *model);
    Check(decoded.unknown.size() == 2, "unknown retained");
    Check(grpcdc::dynamic::EncodeGeneric(*request_type, decoded, *model) == payload,
          "unknown round trip");
  }

  // Loopback: dynamic client against dynamic server.
  {
    auto pair = grpcdc::MemoryTransportPair();
    grpcdc::Server server;
    echo::DynamicEchoService impl;
    grpcdc::dynamic::RegisterDynamicService(server, *model, kService, impl);
    server.ServeTransport(pair.second);
    auto channel = std::make_shared<grpcdc::Channel>(pair.first);
    DynamicClient client(channel, model);
    RunScenarios(client, *model);
  }

  auto cp = JavaClasspath(root);
  if (!cp) {
    std::fprintf(stderr, "TestDynamic OK (loopback; oracle skipped)\n");
    return;
  }

  // Direction A: dynamic client -> bridge -> official server.
  int port = FreePort();
  Proc server;
  if (!Spawn({"java", "-cp", *cp, "dc.oracle.OracleServer", std::to_string(port)},
             true, server) ||
      !WaitReady(server.from_stderr, "READY")) {
    std::fprintf(stderr, "TestDynamic SKIP (oracle server did not start)\n");
    server.Kill();
    return;
  }
  {
    Proc bridge;
    if (!Spawn({"node", root + "/oracle/bridge.mjs", "dc-to-http2", "--grpc",
                "127.0.0.1:" + std::to_string(port)},
               false, bridge)) {
      std::fprintf(stderr, "TestDynamic SKIP (bridge spawn)\n");
      server.Kill();
      return;
    }
    auto transport = std::make_shared<echo::StdioTransport>(bridge.to_stdin,
                                                           bridge.from_stdout);
    auto channel = std::make_shared<grpcdc::Channel>(transport);
    DynamicClient client(channel, model);
    RunScenarios(client, *model);
    bridge.Kill();
  }
  server.Kill();

  // Direction B: official client -> bridge -> dynamic server.
  std::string server_bin = root + "/cpp/build/dynamic_echo_server_stdio";
  if (!FileExists(server_bin)) {
    std::fprintf(stderr, "TestDynamic SKIP (cpp dynamic server not built)\n");
    return;
  }
  int port_b = FreePort();
  Proc bridge;
  if (!Spawn({"node", root + "/oracle/bridge.mjs", "http2-to-dc", "--port",
              std::to_string(port_b), "--target-cmd", server_bin},
             true, bridge) ||
      !WaitReady(bridge.from_stderr, "listening")) {
    std::fprintf(stderr, "TestDynamic SKIP (bridge did not start)\n");
    bridge.Kill();
    return;
  }
  {
    Proc client;
    if (!Spawn({"java", "-cp", *cp, "dc.oracle.OracleClient",
                std::to_string(port_b), root + "/fixtures/oracle_scenarios.txt"},
               true, client)) {
      std::fprintf(stderr, "TestDynamic SKIP (client spawn)\n");
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
  std::fprintf(stderr, "TestDynamic OK\n");
}

}  // namespace tests
