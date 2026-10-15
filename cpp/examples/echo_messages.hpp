#pragma once

#include <cstdint>
#include <string>

#include "examples/pb.hpp"
#include "grpcdc/transport.hpp"

namespace echo {

/// Hand-written protobuf messages for proto/echo.proto (package echo).
///
/// Deliberately minimal (two messages) so the example needs no
/// protobuf codegen dependency — the wire bytes are genuine protobuf:
/// EchoRequest{message:"hi", count:2} encodes to 0a0268691002.
/// Mirrors go/examples/echo_pb.go.
class EchoRequest : public grpcdc::Marshaler, public grpcdc::Unmarshaler {
 public:
  std::string message;
  std::int32_t count = 0;
  std::int32_t delay_ms = 0;

  EchoRequest() = default;
  EchoRequest(std::string msg, std::int32_t cnt)
      : message(std::move(msg)), count(cnt) {}

  grpcdc::Bytes MarshalDc() const override {
    pb::Writer w;
    w.StringField(1, message);
    w.Int32Field(2, count);
    w.Int32Field(3, delay_ms);
    return w.ToBytes();
  }

  void UnmarshalDc(const grpcdc::Bytes& data) override {
    message = "";
    count = 0;
    delay_ms = 0;
    pb::Reader r(data);
    pb::Field field;
    while (r.Next(field)) {
      switch (field.number) {
        case 1: message = field.AsString(); break;
        case 2: count = field.AsInt32(); break;
        case 3: delay_ms = field.AsInt32(); break;
        default: break;  // skip unknown fields
      }
    }
  }

  std::string ToString() const {
    return "EchoRequest{message=" + message + ", count=" +
           std::to_string(count) + ", delayMs=" + std::to_string(delay_ms) + "}";
  }
};

class EchoResponse : public grpcdc::Marshaler, public grpcdc::Unmarshaler {
 public:
  std::string message;
  std::int32_t index = 0;

  EchoResponse() = default;
  EchoResponse(std::string msg, std::int32_t idx)
      : message(std::move(msg)), index(idx) {}

  grpcdc::Bytes MarshalDc() const override {
    pb::Writer w;
    w.StringField(1, message);
    w.Int32Field(2, index);
    return w.ToBytes();
  }

  void UnmarshalDc(const grpcdc::Bytes& data) override {
    message = "";
    index = 0;
    pb::Reader r(data);
    pb::Field field;
    while (r.Next(field)) {
      switch (field.number) {
        case 1: message = field.AsString(); break;
        case 2: index = field.AsInt32(); break;
        default: break;  // skip unknown fields
      }
    }
  }

  std::string ToString() const {
    return "EchoResponse{message=" + message + ", index=" +
           std::to_string(index) + "}";
  }
};

}  // namespace echo
