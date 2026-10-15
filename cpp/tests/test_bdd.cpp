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
#include "tests/bdd_scenarios.hpp"
#include "tests/test_util.hpp"

namespace tests {
namespace {

echo::EchoRequest Req(const std::string& message, std::int32_t count) {
  return echo::EchoRequest(message, count);
}

}  // namespace

/// BDD: interprets the generated behavior scenarios (bdd_scenarios.hpp,
/// stamped from racket/bdd-spec.rkt; prose in BDD.md) against a
/// loopback client+server — the executable examples.
void TestBdd() {
  auto pair = grpcdc::MemoryTransportPair();
  auto server = std::make_shared<grpcdc::Server>();
  static echo::EchoServiceImpl impl;
  echo::EchoGrpcDc::RegisterEchoServer(*server, impl);
  server->ServeTransport(pair.second);
  auto channel = std::make_shared<grpcdc::Channel>(pair.first);
  echo::EchoGrpcDc::EchoClient client(channel);

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
              name + ": " + resp.ToString());
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
              name + ": " + resp.ToString());
        ++got;
      }
      Check(got == c.expectNum, name + ": count");
    } else if (kind == "client-stream") {
      std::vector<echo::EchoRequest> reqs;
      for (auto* m : c.messages) reqs.push_back(Req(m, 0));
      echo::EchoResponse resp = client.ClientStream(reqs);
      Check(resp.message == c.expectMessage && resp.index == c.expectNum,
            name + ": " + resp.ToString());
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
              name + ": " + resp.ToString());
        ++got;
      }
      Check(static_cast<int>(got) == c.expectNum, name + ": count");
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
  std::printf("TestBdd OK\n");
}

}  // namespace tests
