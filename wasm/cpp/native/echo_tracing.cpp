// Browser tracing entry point (native C++/Wasm runtime):
// runs a nested call chain entirely in the worker — client ->
// front callee -> downstream service over in-memory transports —
// with a recording span observer, and reports the spans as JSON
// via on_result so the Playwright driver can assert the trace.
// The inline pump is single-threaded, so client transports poll
// their peer server endpoint on TryRecv (cooperative pumping).

#include <cstdint>
#include <deque>
#include <functional>
#include <memory>
#include <string>
#include <vector>

#include "grpcdc/channel.hpp"
#include "grpcdc/server.hpp"
#include "grpcdc/transport.hpp"
#include "examples/echo_grpc_dc.hpp"
#include "examples/echo_messages.hpp"
#include "examples/echo_service_impl.hpp"

#define GRPCDC_WASM_IMPORT(name) \
  __attribute__((import_module("env"), import_name(name)))

extern "C" {
GRPCDC_WASM_IMPORT("on_result")
void on_result(const char* ptr, std::size_t len);
GRPCDC_WASM_IMPORT("on_error")
void on_error(const char* ptr, std::size_t len);
}

namespace {

using echo::EchoGrpcDc;
using echo::EchoRequest;
using echo::EchoResponse;

EchoRequest Req(const char* message, std::int32_t count) {
  EchoRequest r;
  r.message = message;
  r.count = count;
  return r;
}

struct ByteQueue {
  std::deque<grpcdc::Bytes> items;
};

class QueueTransport : public grpcdc::Transport {
 public:
  QueueTransport(std::shared_ptr<ByteQueue> inbox,
                 std::shared_ptr<ByteQueue> outbox)
      : inbox_(std::move(inbox)), outbox_(std::move(outbox)) {}

  std::function<void()> poll_peer;

  void Send(const grpcdc::Bytes& data) override { outbox_->items.push_back(data); }

  grpcdc::Bytes Recv() override {
    while (true) {
      grpcdc::Bytes out;
      TryRecvResult result = TryRecv(out);
      if (result == TryRecvResult::kMessage) return out;
      if (result == TryRecvResult::kClosed) throw grpcdc::EndOfStream();
    }
  }

  bool HasTryRecv() const override { return true; }

  TryRecvResult TryRecv(grpcdc::Bytes& out) override {
    if (poll_peer) poll_peer();
    if (inbox_->items.empty()) return TryRecvResult::kWouldBlock;
    out = inbox_->items.front();
    inbox_->items.pop_front();
    return TryRecvResult::kMessage;
  }

  void Close() override {}

 private:
  std::shared_ptr<ByteQueue> inbox_;
  std::shared_ptr<ByteQueue> outbox_;
};

struct Start {
  std::string kind, trace_id, span_id, parent_span_id;
};

struct Recorder : grpcdc::Tracing::Tracer {
  std::vector<Start> starts;
  std::vector<std::string> end_kinds;

  void OnStart(const std::string& kind, const std::string&,
               const std::string& trace_id, const std::string& span_id,
               const std::string& parent_span_id) override {
    starts.push_back({kind, trace_id, span_id, parent_span_id});
  }

  void OnEnd(const std::string& kind, const std::string&, const std::string&,
             const std::string&, const std::string&, double) override {
    end_kinds.push_back(kind);
  }
};

class Front : public echo::EchoServiceImpl {
 public:
  explicit Front(std::shared_ptr<grpcdc::Channel> downstream)
      : downstream_(std::move(downstream)) {}

  std::string seen_span;

  EchoResponse Unary(grpcdc::Endpoint::CallContext& ctx, EchoRequest& req) override {
    (void)req;
    if (ctx.trace_context) seen_span = ctx.trace_context->span_id;
    auto bound_channel = downstream_->WithTraceContext(ctx.trace_context);
    EchoGrpcDc::EchoClient bound(
        std::make_shared<grpcdc::Channel>(bound_channel));
    return bound.Unary(Req("nested", 0), nullptr, std::nullopt);
  }

 private:
  std::shared_ptr<grpcdc::Channel> downstream_;
};

std::string JsonEscape(const std::string& s) {
  std::string out;
  for (char c : s) {
    if (c == '"' || c == '\\') out += '\\';
    out += c;
  }
  return out;
}

}  // namespace

extern "C" void run_echo_tracing() {
  Recorder rec;
  grpcdc::Tracing::SetTracer(&rec);
  struct ClearTracer {
    ~ClearTracer() { grpcdc::Tracing::SetTracer(nullptr); }
  } clear_tracer;

  try {
    // Downstream service.
    auto a2_to_b2 = std::make_shared<ByteQueue>();
    auto b2_to_a2 = std::make_shared<ByteQueue>();
    auto a2 = std::make_shared<QueueTransport>(b2_to_a2, a2_to_b2);
    auto b2 = std::make_shared<QueueTransport>(a2_to_b2, b2_to_a2);
    grpcdc::Server back;
    echo::EchoServiceImpl back_impl;
    EchoGrpcDc::RegisterEchoServer(back, back_impl);
    auto back_ep = back.ServeTransport(b2);
    a2->poll_peer = [back_ep] { back_ep->PollOnce(); };
    auto downstream = std::make_shared<grpcdc::Channel>(a2);

    // Front callee.
    Front front(downstream);
    auto a_to_b = std::make_shared<ByteQueue>();
    auto b_to_a = std::make_shared<ByteQueue>();
    auto a = std::make_shared<QueueTransport>(b_to_a, a_to_b);
    auto b = std::make_shared<QueueTransport>(a_to_b, b_to_a);
    grpcdc::Server front_server;
    EchoGrpcDc::RegisterEchoServer(front_server, front);
    auto front_ep = front_server.ServeTransport(b);
    a->poll_peer = [front_ep] { front_ep->PollOnce(); };
    auto channel = std::make_shared<grpcdc::Channel>(a);
    EchoGrpcDc::EchoClient client(channel);

    EchoResponse resp = client.Unary(Req("hello", 0), nullptr, std::nullopt);

    std::string starts_json;
    for (std::size_t i = 0; i < rec.starts.size(); i++) {
      const Start& s = rec.starts[i];
      if (i) starts_json += ",";
      starts_json += "[\"" + JsonEscape(s.kind) + "\",\"" + JsonEscape(s.trace_id) +
                     "\",\"" + JsonEscape(s.span_id) + "\",\"" +
                     JsonEscape(s.parent_span_id) + "\"]";
    }
    std::string ends_json;
    for (std::size_t i = 0; i < rec.end_kinds.size(); i++) {
      if (i) ends_json += ",";
      ends_json += "\"" + JsonEscape(rec.end_kinds[i]) + "\"";
    }
    const std::string json = "{\"message\":\"" + JsonEscape(resp.message) +
                             "\",\"seenSpan\":\"" + JsonEscape(front.seen_span) +
                             "\",\"starts\":[" + starts_json + "],\"ends\":[" +
                             ends_json + "]}";
    on_result(json.data(), json.size());
  } catch (const std::exception& e) {
    on_error(e.what(), std::string(e.what()).size());
  }
}
