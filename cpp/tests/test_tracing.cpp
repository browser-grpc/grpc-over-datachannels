// Tracing: nested callee call joins the trace via the bound channel.

#include <memory>
#include <mutex>
#include <optional>
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

using echo::EchoGrpcDc;
using echo::EchoRequest;
using echo::EchoResponse;

EchoRequest Req(const std::string& message, std::int32_t count) {
  EchoRequest r; r.message = message; r.count = count; return r;
}

struct Start {
  std::string kind, method, trace_id, span_id, parent_span_id;
};

struct Recorder : grpcdc::Tracing::Tracer {
  std::mutex mu;
  std::vector<Start> starts;
  std::vector<double> end_durations;

  void OnStart(const std::string& kind, const std::string& method,
               const std::string& trace_id, const std::string& span_id,
               const std::string& parent_span_id) override {
    std::lock_guard<std::mutex> lock(mu);
    starts.push_back({kind, method, trace_id, span_id, parent_span_id});
  }

  void OnEnd(const std::string& kind, const std::string& method,
             const std::string& trace_id, const std::string& span_id,
             const std::string& status, double duration_ms) override {
    (void)kind; (void)method; (void)trace_id; (void)span_id; (void)status;
    std::lock_guard<std::mutex> lock(mu);
    end_durations.push_back(duration_ms);
  }
};

class Front : public echo::EchoServiceImpl {
 public:
  explicit Front(grpcdc::Channel& downstream) : downstream_(downstream) {}

  std::string seen_span;

  EchoResponse Unary(grpcdc::Endpoint::CallContext& ctx, EchoRequest& req) override {
    (void)req;
    if (ctx.trace_context) seen_span = ctx.trace_context->span_id;
    auto bound_channel = downstream_.WithTraceContext(ctx.trace_context);
    EchoGrpcDc::EchoClient bound(
        std::make_shared<grpcdc::Channel>(bound_channel));
    return bound.Unary(Req("nested", 0), nullptr, std::nullopt);
  }

 private:
  grpcdc::Channel& downstream_;
};

}  // namespace

void TestTracing() {
  Recorder rec;
  grpcdc::Tracing::SetTracer(&rec);
  // The tracer slot is process-global; clear it on exit via scope.
  struct ClearTracer {
    ~ClearTracer() { grpcdc::Tracing::SetTracer(nullptr); }
  } clear_tracer;

  auto back_pair = grpcdc::MemoryTransportPair();
  auto back = std::make_shared<grpcdc::Server>();
  static echo::EchoServiceImpl back_impl;
  EchoGrpcDc::RegisterEchoServer(*back, back_impl);
  back->ServeTransport(back_pair.second);
  grpcdc::Channel downstream_channel(back_pair.first);

  Front front(downstream_channel);
  auto pair = grpcdc::MemoryTransportPair();
  auto front_server = std::make_shared<grpcdc::Server>();
  EchoGrpcDc::RegisterEchoServer(*front_server, front);
  front_server->ServeTransport(pair.second);
  EchoGrpcDc::EchoClient client(std::make_shared<grpcdc::Channel>(pair.first));

  EchoResponse resp = client.Unary(Req("hello", 0), nullptr, std::nullopt);
  Check(resp.message == "echo: nested", "resp " + resp.message);

  std::vector<Start> starts;
  std::vector<double> durations;
  {
    std::lock_guard<std::mutex> lock(rec.mu);
    starts = rec.starts;
    durations = rec.end_durations;
  }
  Check(starts.size() == 4, "starts count");
  Check(starts[0].kind == "client" && starts[1].kind == "server" &&
            starts[2].kind == "client" && starts[3].kind == "server",
        "kinds");
  for (const auto& s : starts) Check(s.trace_id == starts[0].trace_id, "trace ids");
  Check(starts[1].parent_span_id == starts[0].span_id, "server parent");
  Check(starts[2].parent_span_id == starts[1].span_id, "inner client parent");
  Check(starts[3].parent_span_id == starts[2].span_id, "inner server parent");
  Check(front.seen_span == starts[1].span_id, "ctx span");
  Check(durations.size() == 4, "ends count");
  for (double d : durations) Check(d >= 0, "durations");
}

}  // namespace tests
