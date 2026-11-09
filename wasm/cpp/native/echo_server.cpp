// Browser test entry point (native runtime, server role):
// runs the generated C++ Echo server (cpp/examples
// echo_grpc_dc.hpp + echo_service_impl.hpp) over the real
// grpcdc runtime on a DataChannel transport, in a Web
// Worker. The endpoint runs in inline pump mode (TryRecv
// transport), so this loop drives dispatch; handler stream
// waits re-enter PollOnce. The JS client in the Node test
// drives the four call shapes plus a deadline the slow
// handler must miss. Mirrors wasm/swift/native/echo_server.swift.

#include <chrono>
#include <cstdint>
#include <memory>

#include "dc_transport.hpp"
#include "examples/echo_grpc_dc.hpp"
#include "examples/echo_messages.hpp"
#include "examples/echo_service_impl.hpp"

namespace {

class SlowEcho : public echo::EchoServiceImpl {
 public:
  echo::EchoResponse Unary(grpcdc::Endpoint::CallContext& ctx,
                           echo::EchoRequest& req) override {
    if (req.delay_ms > 0) {
      // Busy-wait on the monotonic clock (steady_clock is
      // backed by the worker's WASI clock_time_get).
      const auto until = std::chrono::steady_clock::now() +
                         std::chrono::milliseconds(req.delay_ms);
      while (std::chrono::steady_clock::now() < until) {
      }
    }
    return echo::EchoServiceImpl::Unary(ctx, req);
  }
};

}  // namespace

extern "C" void run_echo_server() {
  grpcdc::Server server;
  SlowEcho impl;
  echo::EchoGrpcDc::RegisterEchoServer(server, impl);
  auto endpoint = server.ServeTransport(std::make_shared<DcTransport>());
  // PollOnce returns promptly when closed; the worker lives
  // for the page's lifetime, so pump forever.
  while (true) {
    endpoint->PollOnce();
  }
}

// Matrix tracing entry: same server with a recording span
// observer; every span start/end re-reports the cumulative
// spans via on_result so the page can expose them to the
// matrix driver (window.__spans) while the pump keeps running.
#define GRPCDC_WASM_IMPORT_SRV(name) \
  __attribute__((import_module("env"), import_name(name)))

extern "C" {
GRPCDC_WASM_IMPORT_SRV("on_result")
void on_result(const char* ptr, std::size_t len);
}

namespace {

struct MatrixServerStart {
  std::string kind, trace_id, span_id, parent_span_id;
};

struct MatrixServerRecorder : grpcdc::Tracing::Tracer {
  std::vector<MatrixServerStart> starts;
  std::vector<std::string> end_kinds;

  void OnStart(const std::string& kind, const std::string&,
               const std::string& trace_id, const std::string& span_id,
               const std::string& parent_span_id) override {
    starts.push_back({kind, trace_id, span_id, parent_span_id});
    Report();
  }

  void OnEnd(const std::string& kind, const std::string&, const std::string&,
             const std::string&, const std::string&, double) override {
    end_kinds.push_back(kind);
    Report();
  }

  void Report() {
    std::string json = "{\"starts\":[";
    for (std::size_t i = 0; i < starts.size(); ++i) {
      if (i) json += ",";
      const MatrixServerStart& s = starts[i];
      json += "[\"" + s.kind + "\",\"" + s.trace_id + "\",\"" + s.span_id +
              "\",\"" + s.parent_span_id + "\"]";
    }
    json += "],\"ends\":[";
    for (std::size_t i = 0; i < end_kinds.size(); ++i) {
      if (i) json += ",";
      json += "\"" + end_kinds[i] + "\"";
    }
    json += "]}";
    on_result(json.data(), json.size());
  }
};

}  // namespace

extern "C" void run_echo_server_tracing() {
  MatrixServerRecorder rec;
  grpcdc::Tracing::SetTracer(&rec);
  grpcdc::Server server;
  SlowEcho impl;
  echo::EchoGrpcDc::RegisterEchoServer(server, impl);
  auto endpoint = server.ServeTransport(std::make_shared<DcTransport>());
  while (true) {
    endpoint->PollOnce();
  }
}
