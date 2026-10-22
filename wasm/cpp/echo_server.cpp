// Browser test entry point (facade server role): registers
// the generated C++ WASM facade server (echo_wasm_dc.hpp)
// whose typed handlers run here in WASM; the page's JS server
// bridge owns the wire. The Node test's JS client drives the
// four call shapes plus a deadline the slow handler must
// miss. Mirrors wasm/zig/echo_server.zig.

#include <chrono>
#include <cstdint>
#include <string>
#include <utility>
#include <vector>

#include "bridge.hpp"
#include "echo_messages.hpp"
#include "echo_wasm_dc.hpp"

namespace {

using echo::EchoRequest;
using echo::EchoResponse;
using echo::EchoWasmGrpcDc;
using grpcdc_wasm::Status;

class SlowEcho : public EchoWasmGrpcDc::EchoServer {
 public:
  std::pair<Status, EchoResponse> Unary(
      const EchoRequest& req,
      const std::vector<grpcdc_wasm::MdPair>& md) override {
    if (req.delay_ms > 0) {
      const auto until = std::chrono::steady_clock::now() +
                         std::chrono::milliseconds(req.delay_ms);
      while (std::chrono::steady_clock::now() < until) {
      }
    }
    if (req.message == "fail") {
      return {{3, "asked to fail"}, EchoResponse{}};
    }
    std::string suffix;
    if (const auto* marker = grpcdc_wasm::MetadataGet(md, "x-echo");
        marker != nullptr && !marker->empty()) {
      suffix = " [" + *marker + "]";
    }
    return {Status::Ok(), EchoResponse{"echo: " + req.message + suffix, 0}};
  }

  Status ServerStream(const EchoRequest& req,
                      const std::vector<grpcdc_wasm::MdPair>&,
                      EchoWasmGrpcDc::EchoServerSink& sink) override {
    if (req.message == "fail") {
      return {3, "asked to fail"};
    }
    for (int i = 0; i < req.count; i++) {
      EchoResponse resp{req.message, i};
      auto st = sink.Send(resp);
      if (!st.ok()) return st;
    }
    return Status::Ok();
  }

  std::pair<Status, EchoResponse> ClientStream(
      const std::vector<EchoRequest>& reqs,
      const std::vector<grpcdc_wasm::MdPair>&) override {
    std::string joined;
    for (std::size_t i = 0; i < reqs.size(); i++) {
      if (reqs[i].message == "fail") {
        return {{3, "asked to fail"}, EchoResponse{}};
      }
      if (i > 0) joined += "+";
      joined += reqs[i].message;
    }
    return {Status::Ok(),
            EchoResponse{joined, static_cast<int>(reqs.size())}};
  }

  Status Bidi(const std::vector<EchoRequest>& reqs,
              const std::vector<grpcdc_wasm::MdPair>&,
              EchoWasmGrpcDc::EchoServerSink& sink) override {
    for (std::size_t i = 0; i < reqs.size(); i++) {
      if (reqs[i].message == "fail") {
        return {3, "asked to fail"};
      }
      EchoResponse resp{reqs[i].message, static_cast<int>(i)};
      auto st = sink.Send(resp);
      if (!st.ok()) return st;
    }
    return Status::Ok();
  }
};

SlowEcho g_impl;

}  // namespace

extern "C" void run_echo_server() {
  EchoWasmGrpcDc::registerEchoServer(g_impl);
}
