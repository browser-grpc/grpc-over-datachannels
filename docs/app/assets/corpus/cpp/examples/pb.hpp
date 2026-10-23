#pragma once

#include <cstdint>
#include <string>

#include "grpcdc/codec.hpp"

namespace echo {

/// Minimal protobuf wire writer/reader for the hand-written messages.
namespace pb {

class Writer {
 public:
  void Varint(std::int64_t value) {
    std::uint64_t v = static_cast<std::uint64_t>(value);
    while ((v & ~0x7fULL) != 0) {
      out_.push_back(static_cast<std::uint8_t>((v & 0x7f) | 0x80));
      v >>= 7;
    }
    out_.push_back(static_cast<std::uint8_t>(v));
  }
  void StringField(int field, const std::string& value) {
    if (value.empty()) return;
    Varint((field << 3) | 2);
    Varint(static_cast<std::int64_t>(value.size()));
    out_.insert(out_.end(), value.begin(), value.end());
  }
  void Int32Field(int field, std::int32_t value) {
    if (value == 0) return;
    Varint((field << 3) | 0);
    Varint(value);
  }
  grpcdc::Bytes ToBytes() const { return out_; }

 private:
  grpcdc::Bytes out_;
};

struct Field {
  int number = 0;
  std::int64_t varint_value = 0;
  grpcdc::Bytes bytes_value;
  int AsInt32() const { return static_cast<std::int32_t>(varint_value); }
  std::string AsString() const {
    return std::string(bytes_value.begin(), bytes_value.end());
  }
};

class Reader {
 public:
  explicit Reader(const grpcdc::Bytes& buf) : buf_(buf) {}

  std::int64_t Varint() {
    std::int64_t result = 0;
    int shift = 0;
    while (true) {
      if (pos_ >= buf_.size()) {
        throw grpcdc::StatusException(grpcdc::wire::kCodeInvalidArgument,
                                      "truncated varint");
      }
      std::uint8_t b = buf_[pos_++];
      result |= static_cast<std::int64_t>(b & 0x7f) << shift;
      if ((b & 0x80) == 0) return result;
      shift += 7;
      if (shift >= 64) {
        throw grpcdc::StatusException(grpcdc::wire::kCodeInvalidArgument,
                                      "varint too long");
      }
    }
  }

  /// Next field; returns false at end.
  bool Next(Field& field) {
    if (pos_ >= buf_.size()) return false;
    std::int64_t tag = Varint();
    field = Field{};
    field.number = static_cast<int>(tag >> 3);
    switch (static_cast<int>(tag & 7)) {
      case 0:
        field.varint_value = Varint();
        return true;
      case 2: {
        std::size_t n = static_cast<std::size_t>(Varint());
        if (pos_ + n > buf_.size()) {
          throw grpcdc::StatusException(grpcdc::wire::kCodeInvalidArgument,
                                        "truncated bytes field");
        }
        field.bytes_value.assign(buf_.begin() + pos_, buf_.begin() + pos_ + n);
        pos_ += n;
        return true;
      }
      case 1: {
        if (pos_ + 8 > buf_.size()) {
          throw grpcdc::StatusException(grpcdc::wire::kCodeInvalidArgument,
                                        "truncated fixed64");
        }
        field.bytes_value.assign(buf_.begin() + pos_, buf_.begin() + pos_ + 8);
        pos_ += 8;
        return true;
      }
      case 5: {
        if (pos_ + 4 > buf_.size()) {
          throw grpcdc::StatusException(grpcdc::wire::kCodeInvalidArgument,
                                        "truncated fixed32");
        }
        field.bytes_value.assign(buf_.begin() + pos_, buf_.begin() + pos_ + 4);
        pos_ += 4;
        return true;
      }
      default:
        throw grpcdc::StatusException(grpcdc::wire::kCodeInvalidArgument,
                                      "bad wire type");
    }
  }

 private:
  const grpcdc::Bytes& buf_;
  std::size_t pos_ = 0;
};

}  // namespace pb
}  // namespace echo
