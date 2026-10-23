#include <future>
#include <memory>
#include <string>
#include <vector>

#include "examples/echo_grpc_dc.hpp"
#include "examples/echo_messages.hpp"
#include "examples/echo_service_impl.hpp"
#include "grpcdc/channel.hpp"
#include "grpcdc/memory_transport.hpp"
#include "grpcdc/server.hpp"
#include "tests/test_util.hpp"

namespace tests {
namespace {

echo::EchoRequest Req(const std::string& message, std::int32_t count) {
  echo::EchoRequest r; r.message = message; r.count = count; return r;
}

std::shared_ptr<echo::EchoGrpcDc::EchoClient> Setup() {
  auto pair = grpcdc::MemoryTransportPair();
  auto server = std::make_shared<grpcdc::Server>();
  static echo::EchoServiceImpl impl;
  echo::EchoGrpcDc::RegisterEchoServer(*server, impl);
  server->ServeTransport(pair.second);
  auto channel = std::make_shared<grpcdc::Channel>(pair.first);
  return std::make_shared<echo::EchoGrpcDc::EchoClient>(channel);
}

/// Async implementation used to test RegisterEchoServerAsync.
class AsyncEchoService : public echo::EchoGrpcDc::EchoServerAsync {
 public:
  std::future<echo::EchoResponse> UnaryAsync(
      grpcdc::Endpoint::CallContext& ctx, echo::EchoRequest& req) override {
    return std::async(std::launch::async,
                      [this, &ctx, &req] { return inner_.Unary(ctx, req); });
  }
  std::future<void> ServerStreamAsync(
      echo::EchoRequest& req,
      echo::EchoGrpcDc::EchoServerStreamServer& stream) override {
    return std::async(std::launch::async,
                      [this, &req, &stream] { inner_.ServerStream(req, stream); });
  }
  std::future<void> ClientStreamAsync(
      echo::EchoGrpcDc::EchoClientStreamServer& stream) override {
    return std::async(std::launch::async,
                      [this, &stream] { inner_.ClientStream(stream); });
  }
  std::future<void> BidiAsync(echo::EchoGrpcDc::EchoBidiServer& stream) override {
    return std::async(std::launch::async,
                      [this, &stream] { inner_.Bidi(stream); });
  }

 private:
  echo::EchoServiceImpl inner_;
};

void RunAsync() {
  // Async client surface against the sync loopback server.
  auto client = Setup();
  echo::EchoResponse unary = client->UnaryAsync(Req("hello", 0)).get();
  Check(unary.message == "echo: hello", "async unary: " + unary.message);

  auto streamed = client->ServerStreamAsync(Req("tick", 3)).get();
  Check(streamed.size() == 3 && streamed[0].index == 0 && streamed[2].index == 2,
        "async server stream");

  echo::EchoResponse joined =
      client->ClientStreamAsync({Req("a", 0), Req("b", 0)}).get();
  Check(joined.message == "a+b", "async client stream: " + joined.message);

  auto echoed = client->BidiAsync({Req("x", 0), Req("y", 0)}).get();
  Check(echoed.size() == 2 && echoed[1].message == "y", "async bidi");

  // Async server registration: async impl served over loopback.
  auto pair = grpcdc::MemoryTransportPair();
  grpcdc::Server server;
  AsyncEchoService async_impl;
  echo::EchoGrpcDc::RegisterEchoServerAsync(server, async_impl);
  server.ServeTransport(pair.second);
  auto channel = std::make_shared<grpcdc::Channel>(pair.first);
  echo::EchoGrpcDc::EchoClient client2(channel);
  echo::EchoResponse resp = client2.Unary(Req("hello", 0));
  Check(resp.message == "echo: hello", "async server unary: " + resp.message);
}

}  // namespace

/// Loopback end-to-end: all four shapes, error status, metadata.
void TestEcho() {
  auto client = Setup();

  echo::EchoResponse unary = client->Unary(Req("hello", 0));
  Check(unary.message == "echo: hello" && unary.index == 0,
        "unary: " + unary.message);

  auto stream = client->ServerStream(Req("tick", 3));
  std::vector<std::int32_t> indexes;
  while (true) {
    echo::EchoResponse resp;
    try {
      resp = stream.Recv();
    } catch (const grpcdc::EndOfStream&) {
      break;
    }
    Check(resp.message == "tick", "stream message: " + resp.message);
    indexes.push_back(resp.index);
  }
  Check((indexes == std::vector<std::int32_t>{0, 1, 2}), "stream indexes");

  echo::EchoResponse joined =
      client->ClientStream({Req("a", 0), Req("b", 0), Req("c", 0)});
  Check(joined.message == "a+b+c" && joined.index == 3,
        "client stream: " + joined.message);

  auto bidi = client->Bidi({Req("x", 0), Req("y", 0)});
  std::vector<std::string> echoed;
  while (true) {
    echo::EchoResponse resp;
    try {
      resp = bidi.Recv();
    } catch (const grpcdc::EndOfStream&) {
      break;
    }
    echoed.push_back(resp.message);
  }
  Check((echoed == std::vector<std::string>{"x", "y"}), "bidi");

  try {
    client->Unary(Req("fail", 0));
    Check(false, "fail call should throw");
  } catch (const grpcdc::StatusException& e) {
    Check(e.code() == 3, "fail status: " + std::string(e.what()));
  }

  grpcdc::Metadata md{{"x-echo", "meta"}};
  echo::EchoResponse with_md = client->Unary(Req("hello", 0), &md);
  Check(with_md.message == "echo: hello [meta]",
        "metadata: " + with_md.message);

  RunAsync();
  std::fprintf(stderr, "TestEcho OK\n");
}

}  // namespace tests
