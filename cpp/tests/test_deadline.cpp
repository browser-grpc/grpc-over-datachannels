// Deadlines: grpc-timeout propagation + DEADLINE_EXCEEDED
// enforcement in blocking Recv; CallContext carries the budget.

#include <chrono>
#include <memory>
#include <string>
#include <thread>
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

using echo::EchoGrpcDc;
using echo::EchoRequest;
using echo::EchoResponse;
using std::chrono::milliseconds;

EchoRequest Req(const std::string& message, std::int32_t count) {
  EchoRequest r; r.message = message; r.count = count; return r;
}

class SlowEcho : public echo::EchoServiceImpl {
 public:
  grpcdc::Endpoint::CallContext seen_ctx;
  bool seen = false;

  EchoResponse Unary(grpcdc::Endpoint::CallContext& ctx, EchoRequest& req) override {
    seen_ctx = ctx;
    seen = true;
    std::this_thread::sleep_for(milliseconds(400));
    return echo::EchoServiceImpl::Unary(ctx, req);
  }

  void ServerStream(EchoRequest& req,
                    EchoGrpcDc::EchoServerStreamServer& stream) override {
    for (std::int32_t i = 0; i < std::max(0, req.count); ++i) {
      if (i > 0) std::this_thread::sleep_for(milliseconds(300));
      EchoResponse resp; resp.message = req.message; resp.index = i;
      stream.Send(resp);
    }
  }
};

}  // namespace

void TestDeadline() {
  Check(grpcdc::Codec::ParseTimeout(grpcdc::Codec::EncodeTimeout(milliseconds(250)))
            == milliseconds(250),
        "timeout round trip");
  Check(!grpcdc::Codec::ParseTimeout("10x").has_value(), "junk timeout");

  auto pair = grpcdc::MemoryTransportPair();
  auto server = std::make_shared<grpcdc::Server>();
  static SlowEcho impl;
  EchoGrpcDc::RegisterEchoServer(*server, impl);
  server->ServeTransport(pair.second);
  EchoGrpcDc::EchoClient client(std::make_shared<grpcdc::Channel>(pair.first));

  auto start = std::chrono::steady_clock::now();
  bool timed_out = false;
  try {
    (void)client.Unary(Req("hello", 0), nullptr, milliseconds(50));
  } catch (const grpcdc::StatusException& e) {
    timed_out = true;
    Check(e.code() == grpcdc::wire::kCodeDeadlineExceeded, "unary code");
  }
  Check(timed_out, "unary deadline raised");
  Check(std::chrono::steady_clock::now() - start < milliseconds(350),
        "deadline fires fast");
  Check(impl.seen, "handler ran");
  Check(impl.seen_ctx.metadata.count("grpc-timeout") == 1, "grpc-timeout metadata");
  Check(impl.seen_ctx.deadline.has_value(), "ctx deadline");
  Check(impl.seen_ctx.TimeRemaining().has_value(), "ctx remaining");

  auto stream = client.ServerStream(Req("tick", 5), nullptr, milliseconds(150));
  Check(stream.Recv().index == 0, "stream first");
  bool stream_timed_out = false;
  try {
    (void)stream.Recv();
  } catch (const grpcdc::StatusException& e) {
    stream_timed_out = true;
    Check(e.code() == grpcdc::wire::kCodeDeadlineExceeded, "stream code");
  }
  Check(stream_timed_out, "stream deadline raised");

  EchoResponse joined =
      client.ClientStream({Req("a", 0), Req("b", 0)}, nullptr, std::chrono::seconds(5));
  Check(joined.message == "a+b", "generous timeout succeeds");
}

}  // namespace tests
