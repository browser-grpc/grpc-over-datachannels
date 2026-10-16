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
