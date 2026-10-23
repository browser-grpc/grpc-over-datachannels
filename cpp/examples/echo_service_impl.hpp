#pragma once

#include <algorithm>
#include <chrono>
#include <string>
#include <thread>
#include <vector>

#include "examples/echo_grpc_dc.hpp"

namespace echo {

/// Reference Echo implementation (mirrors the Rust/JS/Go/Python/Java
/// demos): "fail" is rejected, everything else echoes.
class EchoServiceImpl : public EchoGrpcDc::EchoServer {
 public:
  EchoResponse Unary(grpcdc::Endpoint::CallContext& ctx, EchoRequest& req) override {
    if (req.message == "fail") {
      throw grpcdc::StatusException(grpcdc::wire::kCodeInvalidArgument,
                                    "asked to fail");
    }
    if (req.delay_ms > 0) {
      std::this_thread::sleep_for(std::chrono::milliseconds(req.delay_ms));
    }
    std::string suffix;
    auto it = ctx.metadata.find("x-echo");
    if (it != ctx.metadata.end() && !it->second.empty()) {
      suffix = " [" + it->second + "]";
    }
    { EchoResponse resp; resp.message = "echo: " + req.message + suffix; resp.index = 0; return resp; }
  }

  void ServerStream(EchoRequest& req,
                    EchoGrpcDc::EchoServerStreamServer& stream) override {
    if (req.message == "fail") {
      throw grpcdc::StatusException(grpcdc::wire::kCodeInvalidArgument,
                                    "asked to fail");
    }
    for (std::int32_t i = 0; i < std::max(0, req.count); ++i) {
      EchoResponse resp; resp.message = req.message; resp.index = i;
      stream.Send(resp);
    }
  }

  void ClientStream(EchoGrpcDc::EchoClientStreamServer& stream) override {
    std::vector<std::string> parts;
    while (true) {
      EchoRequest req;
      try {
        req = stream.Recv();
      } catch (const grpcdc::EndOfStream&) {
        break;
      }
      if (req.message == "fail") {
        throw grpcdc::StatusException(grpcdc::wire::kCodeInvalidArgument,
                                      "asked to fail");
      }
      parts.push_back(req.message);
    }
    std::string joined;
    for (std::size_t i = 0; i < parts.size(); ++i) {
      if (i) joined += "+";
      joined += parts[i];
    }
    EchoResponse resp; resp.message = joined; resp.index = static_cast<std::int32_t>(parts.size());
    stream.SendAndClose(resp);
  }

  void Bidi(EchoGrpcDc::EchoBidiServer& stream) override {
    std::int32_t index = 0;
    while (true) {
      EchoRequest req;
      try {
        req = stream.Recv();
      } catch (const grpcdc::EndOfStream&) {
        return;
      }
      if (req.message == "fail") {
        throw grpcdc::StatusException(grpcdc::wire::kCodeInvalidArgument,
                                      "asked to fail");
      }
      EchoResponse resp; resp.message = req.message; resp.index = index++;
      stream.Send(resp);
    }
  }
};

}  // namespace echo
