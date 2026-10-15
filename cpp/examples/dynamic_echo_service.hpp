#pragma once

#include <string>
#include <vector>

#include "grpcdc/dynamic.hpp"

namespace echo {

/// Dynamic Echo implementation: the reference Echo semantics built
/// purely on the descriptor-driven runtime (no generated stubs).
/// Field numbers come from proto/echo.proto: EchoRequest{message=1,
/// count=2}, EchoResponse{message=1, index=2}.
class DynamicEchoService : public grpcdc::dynamic::DynamicHandler {
 public:
  grpcdc::dynamic::GenericMessage Unary(
      grpcdc::Endpoint::CallContext& ctx,
      const grpcdc::dynamic::MethodModel& method,
      grpcdc::dynamic::GenericMessage req) override {
    std::string message = req.GetString(1);
    if (message == "fail") {
      throw grpcdc::StatusException(grpcdc::wire::kCodeInvalidArgument,
                                    "asked to fail");
    }
    std::string suffix;
    auto it = ctx.metadata.find("x-echo");
    if (it != ctx.metadata.end() && !it->second.empty()) {
      suffix = " [" + it->second + "]";
    }
    return Response(method, "echo: " + message + suffix, 0);
  }

  void ServerStream(grpcdc::Endpoint::CallContext&,
                    const grpcdc::dynamic::MethodModel& method,
                    grpcdc::dynamic::GenericMessage req,
                    grpcdc::dynamic::SendFn& send) override {
    std::int64_t count = req.GetInt(2);
    for (std::int64_t i = 0; i < count; ++i) {
      send(Response(method, req.GetString(1), i));
    }
  }

  grpcdc::dynamic::GenericMessage ClientStream(
      grpcdc::Endpoint::CallContext&,
      const grpcdc::dynamic::MethodModel& method,
      grpcdc::dynamic::RecvFn& recv) override {
    std::vector<std::string> parts;
    while (true) {
      grpcdc::dynamic::GenericMessage req;
      try {
        req = recv();
      } catch (const grpcdc::EndOfStream&) {
        break;
      }
      parts.push_back(req.GetString(1));
    }
    std::string joined;
    for (std::size_t i = 0; i < parts.size(); ++i) {
      if (i) joined += "+";
      joined += parts[i];
    }
    return Response(method, joined, static_cast<std::int64_t>(parts.size()));
  }

  void Bidi(grpcdc::Endpoint::CallContext&,
            const grpcdc::dynamic::MethodModel& method,
            grpcdc::dynamic::RecvFn& recv,
            grpcdc::dynamic::SendFn& send) override {
    std::int64_t index = 0;
    while (true) {
      grpcdc::dynamic::GenericMessage req;
      try {
        req = recv();
      } catch (const grpcdc::EndOfStream&) {
        return;
      }
      send(Response(method, req.GetString(1), index++));
    }
  }

 private:
  static grpcdc::dynamic::GenericMessage Response(
      const grpcdc::dynamic::MethodModel& method, const std::string& message,
      std::int64_t index) {
    grpcdc::dynamic::GenericMessage resp(method.output);
    resp.Set(1, grpcdc::dynamic::GenericValue(message));
    resp.Set(2, grpcdc::dynamic::GenericValue(index));
    return resp;
  }
};

}  // namespace echo
