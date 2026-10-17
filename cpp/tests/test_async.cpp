// C++20 coroutine surface: grpcdc::Task + generated EchoClientCoro
// over loopback. Built standalone with -std=c++20 (see Makefile);
// the rest of the C++ suite stays on C++17.

#include <cstdio>
#include <memory>
#include <string>
#include <vector>

#include "examples/echo_grpc_dc.hpp"
#include "examples/echo_messages.hpp"
#include "examples/echo_service_impl.hpp"
#include "grpcdc/async.hpp"
#include "grpcdc/memory_transport.hpp"
#include "grpcdc/server.hpp"
#include "tests/test_util.hpp"

namespace {

using echo::EchoGrpcDc;
using echo::EchoRequest;
using echo::EchoResponse;

EchoRequest Req(const std::string& message, std::int32_t count) {
  EchoRequest r; r.message = message; r.count = count; return r;
}

std::shared_ptr<EchoGrpcDc::EchoClientCoro> Setup() {
  auto pair = grpcdc::MemoryTransportPair();
  auto server = std::make_shared<grpcdc::Server>();
  static echo::EchoServiceImpl impl;
  EchoGrpcDc::RegisterEchoServer(*server, impl);
  server->ServeTransport(pair.second);
  auto channel = std::make_shared<grpcdc::Channel>(pair.first);
  return std::make_shared<EchoGrpcDc::EchoClientCoro>(channel);
}

grpcdc::Task<void> Run() {
  auto client = Setup();

  EchoResponse unary = co_await client->Unary(Req("hello", 0));
  tests::Check(unary.message == "echo: hello", "coro unary");
  tests::Check(unary.index == 0, "coro unary index");

  auto stream = co_await client->ServerStream(Req("tick", 3));
  std::vector<std::int32_t> indexes;
  for (;;) {
    auto resp = co_await stream.Recv();
    if (!resp) break;
    indexes.push_back(resp->index);
    tests::Check(resp->message == "tick", "coro tick");
  }
  tests::Check(indexes == std::vector<std::int32_t>({0, 1, 2}), "coro indexes");

  EchoResponse joined =
      co_await client->ClientStream({Req("a", 0), Req("b", 0), Req("c", 0)});
  tests::Check(joined.message == "a+b+c", "coro client stream");

  auto bidi = co_await client->Bidi({Req("x", 0), Req("y", 0)});
  std::vector<std::string> echoed;
  for (;;) {
    auto resp = co_await bidi.Recv();
    if (!resp) break;
    echoed.push_back(resp->message);
  }
  tests::Check(echoed == std::vector<std::string>({"x", "y"}), "coro bidi");

  bool failed = false;
  try {
    (void)co_await client->Unary(Req("fail", 0));
  } catch (const grpcdc::StatusException& e) {
    failed = true;
    tests::Check(e.code() == 3, "coro error code");
  }
  tests::Check(failed, "coro error raised");
}

grpcdc::Task<void> RunCancellation() {
  auto client = Setup();
  auto stream = co_await client->ServerStream(Req("tick", 100000));
  auto first = co_await stream.Recv();
  tests::Check(first.has_value(), "coro cancel first");
  stream.Cancel();
  bool cancelled = false;
  try {
    for (;;) {
      auto resp = co_await stream.Recv();
      if (!resp) break;
    }
  } catch (const grpcdc::StatusException& e) {
    cancelled = true;
    tests::Check(e.code() == grpcdc::wire::kCodeCancelled, "coro cancelled code");
  }
  tests::Check(cancelled, "coro cancelled raised");
  EchoResponse after = co_await client->Unary(Req("after", 0));
  tests::Check(after.message == "echo: after", "coro after cancel");
}

}  // namespace

int main() {
  try {
    grpcdc::SyncWait(Run());
    grpcdc::SyncWait(RunCancellation());
  } catch (const std::exception& e) {
    std::fprintf(stderr, "test_async failed: %s\n", e.what());
    return 1;
  }
  std::printf("test_async (coroutines) passed\n");
  return 0;
}
