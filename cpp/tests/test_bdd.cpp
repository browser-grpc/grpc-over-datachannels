#include <cstdint>
#include <memory>
#include <string>
#include <vector>

#include "examples/echo_grpc_dc.hpp"
#include "examples/echo_messages.hpp"
#include "examples/echo_service_impl.hpp"
#include "grpcdc/channel.hpp"
#include "grpcdc/memory_transport.hpp"
#include "grpcdc/server.hpp"
#include "tests/bdd_sidecar.hpp"
#include "tests/bdd_scenarios.hpp"
#include "tests/test_util.hpp"

namespace tests {
namespace {

echo::EchoRequest Req(const std::string& message, std::int32_t count) {
  echo::EchoRequest r; r.message = message; r.count = count; return r;
}

}  // namespace

/// BDD: interprets the generated behavior scenarios (bdd_scenarios.hpp,
/// generated from the BDD specification; prose in BDD.md) against a
/// loopback client+server — the executable examples.
void TestBdd() {
  auto pair = grpcdc::MemoryTransportPair();
  auto server = std::make_shared<grpcdc::Server>();
  static echo::EchoServiceImpl impl;
  echo::EchoGrpcDc::RegisterEchoServer(*server, impl);
  server->ServeTransport(pair.second);
  auto channel = std::make_shared<grpcdc::Channel>(pair.first);
  echo::EchoGrpcDc::EchoClient client(channel);
  RunBddScenarios(channel, client);
  std::printf("TestBdd OK\n");
}

void RunBddScenarios(std::shared_ptr<grpcdc::Channel> channel,
                     echo::EchoGrpcDc::EchoClient& client) {
  for (const auto& c : BddCases()) {
    const std::string name = c.name;
    const std::string kind = c.kind;
    if (kind == "unary") {
      grpcdc::Metadata md;
      const grpcdc::Metadata* md_ptr = nullptr;
      if (c.metadata[0] != '\0') {
        md["x-echo"] = c.metadata;
        md_ptr = &md;
      }
      try {
        echo::EchoResponse resp = client.Unary(Req(c.messages[0], 0), md_ptr);
        Check(c.expectStatus < 0, name + ": expected failure");
        Check(resp.message == c.expectMessage && resp.index == c.expectNum,
              name + ": " + resp.message);
      } catch (const grpcdc::StatusException& e) {
        Check(c.expectStatus >= 0 && e.code() == c.expectStatus,
              name + ": status " + std::string(e.what()));
      }
    } else if (kind == "server-stream") {
      auto stream = client.ServerStream(Req(c.messages[0], c.count));
      int got = 0;
      while (true) {
        echo::EchoResponse resp;
        try {
          resp = stream.Recv();
        } catch (const grpcdc::EndOfStream&) {
          break;
        }
        Check(resp.message == c.expectMessage && resp.index == got,
              name + ": " + resp.message);
        ++got;
      }
      Check(got == c.expectNum, name + ": count");
    } else if (kind == "client-stream") {
      std::vector<echo::EchoRequest> reqs;
      for (auto* m : c.messages) reqs.push_back(Req(m, 0));
      echo::EchoResponse resp = client.ClientStream(reqs);
      Check(resp.message == c.expectMessage && resp.index == c.expectNum,
            name + ": " + resp.message);
    } else if (kind == "bidi") {
      std::vector<echo::EchoRequest> reqs;
      for (auto* m : c.messages) reqs.push_back(Req(m, 0));
      auto stream = client.Bidi(reqs);
      size_t got = 0;
      while (true) {
        echo::EchoResponse resp;
        try {
          resp = stream.Recv();
        } catch (const grpcdc::EndOfStream&) {
          break;
        }
        Check(got < c.messages.size() &&
                  resp.message == c.messages[got] &&
                  resp.index == static_cast<std::int32_t>(got),
              name + ": " + resp.message);
        ++got;
      }
      Check(static_cast<int>(got) == c.expectNum, name + ": count");
    } else if (kind == "server-stream-fail") {
      auto stream = client.ServerStream(Req(c.messages[0], c.count));
      try {
        while (true) { stream.Recv(); }
      } catch (const grpcdc::StatusException& e) {
        Check(e.code() == c.expectStatus,
              name + ": status " + std::string(e.what()));
      } catch (const grpcdc::EndOfStream&) {
        Check(false, name + ": expected failure, stream ended OK");
      }
    } else if (kind == "bidi-fail") {
      std::vector<echo::EchoRequest> reqs;
      for (auto* m : c.messages) reqs.push_back(Req(m, 0));
      auto stream = client.Bidi(reqs);
      try {
        while (true) { stream.Recv(); }
      } catch (const grpcdc::StatusException& e) {
        Check(e.code() == c.expectStatus,
              name + ": status " + std::string(e.what()));
      } catch (const grpcdc::EndOfStream&) {
        Check(false, name + ": expected failure, stream ended OK");
      }
    } else if (kind == "deadline") {
      echo::EchoRequest delayed = Req(c.messages[0], 0);
      delayed.delay_ms = c.count;
      try {
        client.Unary(delayed, nullptr, std::chrono::milliseconds(100));
        Check(false, name + ": expected deadline failure");
      } catch (const grpcdc::StatusException& e) {
        Check(e.code() == c.expectStatus,
              name + ": status " + std::string(e.what()));
      }
    } else if (kind == "cancel") {
      auto stream = channel->ServerStream("/echo.Echo/ServerStream", Req(c.messages[0], c.count));
      echo::EchoResponse first;
      stream.Recv(first);
      Check(first.message == c.messages[0], name + ": first");
      channel->Cancel(stream);
      bool terminated = false;
      try {
        for (int i = 0; i < c.count + 2 && !terminated; ++i) {
          echo::EchoResponse resp;
          stream.Recv(resp);
        }
      } catch (...) {
        terminated = true;
      }
      Check(terminated, name + ": stream did not terminate after cancel");
    } else if (kind == "raw-unary") {
      try {
        echo::EchoResponse resp;
        channel->Unary(c.path, Req(c.messages[0], 0), resp);
        Check(false, name + ": expected failure");
      } catch (const grpcdc::StatusException& e) {
        Check(e.code() == c.expectStatus,
              name + ": status " + std::string(e.what()));
      }
    } else {
      Check(false, "unknown bdd kind: " + kind);
    }
  }
}

}  // namespace tests
