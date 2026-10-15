#pragma once

#include <algorithm>
#include <string>
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
    std::string suffix;
    auto it = ctx.metadata.find("x-echo");
    if (it != ctx.metadata.end() && !it->second.empty()) {
      suffix = " [" + it->second + "]";
    }
    return EchoResponse("echo: " + req.message + suffix, 0);
  }

  void ServerStream(EchoRequest& req,
                    EchoGrpcDc::EchoServerStreamServer& stream) override {
    for (std::int32_t i = 0; i < std::max(0, req.count); ++i) {
      EchoResponse resp(req.message, i);
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
      parts.push_back(req.message);
    }
    std::string joined;
    for (std::size_t i = 0; i < parts.size(); ++i) {
      if (i) joined += "+";
      joined += parts[i];
    }
    EchoResponse resp(joined, static_cast<std::int32_t>(parts.size()));
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
      EchoResponse resp(req.message, index++);
      stream.Send(resp);
    }
  }
};

}  // namespace echo
