#pragma once

#include <cstdint>
#include <string>

#include "pb.hpp"

namespace echo {

/// Hand-written protobuf messages for proto/echo.proto
/// (package echo), exception-free for the WASM build.
/// Mirrors cpp/examples/echo_messages.hpp; UnmarshalDc
/// returns false on malformed input instead of throwing.
class EchoRequest {
 public:
  std::string message;
  std::int32_t count = 0;
  std::int32_t delay_ms = 0;

  EchoRequest() = default;
  EchoRequest(std::string msg, std::int32_t cnt)
      : message(std::move(msg)), count(cnt) {}

  grpcdc_wasm::Bytes MarshalDc() const {
    pb::Writer w;
    w.StringField(1, message);
    w.Int32Field(2, count);
    w.Int32Field(3, delay_ms);
    return w.ToBytes();
  }

  bool UnmarshalDc(const grpcdc_wasm::Bytes& data) {
    message = "";
    count = 0;
    delay_ms = 0;
    pb::Reader r(data);
    pb::Field field;
    while (true) {
      const int step = r.Next(field);
      if (step == 0) return true;
      if (step < 0) return false;
      switch (field.number) {
        case 1: message = field.AsString(); break;
        case 2: count = field.AsInt32(); break;
        case 3: delay_ms = field.AsInt32(); break;
        default: break;  // skip unknown fields
      }
    }
  }
};

class EchoResponse {
 public:
  std::string message;
  std::int32_t index = 0;

  EchoResponse() = default;
  EchoResponse(std::string msg, std::int32_t idx)
      : message(std::move(msg)), index(idx) {}

  grpcdc_wasm::Bytes MarshalDc() const {
    pb::Writer w;
    w.StringField(1, message);
    w.Int32Field(2, index);
    return w.ToBytes();
  }

  bool UnmarshalDc(const grpcdc_wasm::Bytes& data) {
    message = "";
    index = 0;
    pb::Reader r(data);
    pb::Field field;
    while (true) {
      const int step = r.Next(field);
      if (step == 0) return true;
      if (step < 0) return false;
      switch (field.number) {
        case 1: message = field.AsString(); break;
        case 2: index = field.AsInt32(); break;
        default: break;  // skip unknown fields
      }
    }
  }
};

}  // namespace echo
