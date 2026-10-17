// Browser test entry point (facade stream server role):
// registers the generated incremental EchoStreamServer whose
// handlers are fed one request at a time through the
// serve_*Start/Feed/End exports; the page's JS server bridge
// owns the wire via registerClientStreamInc/registerBidiInc.
// Bidi answers each request as it lands (ping-pong proof).

#include <cstdint>
#include <map>
#include <string>
#include <vector>

#include "echo_wasm_dc.hpp"

namespace {

struct CallState {
  std::vector<std::string> parts;
  std::int32_t index = 0;
};

class SlowEchoStream final : public echo::EchoWasmGrpcDc::EchoStreamServer {
 public:
  void ClientStreamBegin(std::uint32_t call_id,
                         const std::vector<grpcdc_wasm::MdPair>&) override {
    states_[call_id] = CallState{};
  }

  void ClientStreamRequest(std::uint32_t call_id,
                           const echo::EchoRequest& req) override {
    states_[call_id].parts.push_back(req.message);
  }

  std::pair<grpcdc_wasm::Status, echo::EchoResponse> ClientStreamEnd(
      std::uint32_t call_id) override {
    auto it = states_.find(call_id);
    std::string joined;
    std::int32_t count = 0;
    if (it != states_.end()) {
      count = static_cast<std::int32_t>(it->second.parts.size());
      for (std::size_t i = 0; i < it->second.parts.size(); i++) {
        if (i > 0) joined += "+";
        joined += it->second.parts[i];
      }
      states_.erase(it);
    }
    return {grpcdc_wasm::Status::Ok(), echo::EchoResponse{joined, count}};
  }

  void BidiBegin(std::uint32_t call_id,
                 const std::vector<grpcdc_wasm::MdPair>&) override {
    states_[call_id] = CallState{};
  }

  grpcdc_wasm::Status BidiRequest(
      std::uint32_t call_id, const echo::EchoRequest& req,
      echo::EchoWasmGrpcDc::EchoServerSink& sink) override {
    auto& state = states_[call_id];
    auto status = sink.Send(echo::EchoResponse{req.message, state.index});
    state.index += 1;
    return status;
  }

  grpcdc_wasm::Status BidiEnd(std::uint32_t call_id) override {
    states_.erase(call_id);
    return grpcdc_wasm::Status::Ok();
  }

 private:
  std::map<std::uint32_t, CallState> states_;
};

SlowEchoStream g_impl;

}  // namespace

extern "C" void run_echo_stream_server() {
  echo::EchoWasmGrpcDc::registerEchoStreamServer(g_impl);
}
